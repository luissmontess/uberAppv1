defmodule TaxiBeWeb.TaxiAllocationJob do
  # En esta primera version el proceso inicial ordena los conductores por proximidad al cliente

  # Esta llama a una funcion auxiliar llamada :block1, la cual hace match con el request,
  # un arreglo de taxistas, y un estado NotAccepted (mantiene el proceso si es que sigue en NotAccepted)
  # en esta funcion, manda la peticion de cliente al conductor y edita el estado para tomar en cuenta
  # la cola de la lista de conductores, efectivamente descartando el conductor en turno para futuras
  # llamadas de la funcion

  # Este ultimo punto es importante, porque en caso de no ser aun aceptada la peticion despues de
  # 15 segundos, se llama nuevamente la funcion :block1 para mandar la peticion al siguiente
  # conductor

  # Al terminarse todos los conductores, representado por una condicional if taxis != [],
  # se notifica al cliente que hubo un problema encontrando un conductor

  # Por otro lado, si en algun momento valido es aceptada la peticion, el estado :status
  # cambia a Accepted, y no permite la peticion ser aceptada por otro conductor

  # Si la peticion es aceptada en un momento no valido, se notifica al conductor
  # que se ha tardado mucho tiempo en contestar y no es posible aceptar.

  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request}}
  end

  def handle_info(:step1, %{request: request}) do
    Process.send(self(), :block1, [:nosuspend])

    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)

    Task.await(task)

    %{"pickup_address" => pickup} = request

    clientcoord = TaxiBeWeb.Geolocator.geocode(pickup)
    {_, clientpos} = clientcoord
    taxis = select_candidate_taxis(request)

    dbtaxis = orderTaxis(clientpos, taxis)
    IO.inspect(dbtaxis)
    {:noreply, %{request: request, candidates: dbtaxis, status: NotAccepted}}
  end


  def handle_info(:block1, %{request: request, candidates: taxis, status: NotAccepted} = state) do
    if taxis != [] do
      taxi = hd(taxis)
      %{
        "pickup_address" => pickup_address,
        "dropoff_address" => dropoff_address,
        "booking_id" => booking_id
      } = request

      TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
        %{
          msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
          bookingId: booking_id,
          status: true
      })

      Process.send_after(self(),:timeout1, 15000)
      {:noreply, %{request: request, candidates: tl(taxis), contacted_taxi: taxi, status: NotAccepted}}
    else
      %{
        "username" => customer_username
      } = request

      TaxiBeWeb.Endpoint.broadcast("customer:"<>customer_username, "booking_request", %{msg: "Hubo un problema"})
      {:noreply, %{state | contacted_taxi: ""}}
    end
  end

  def handle_info(:timeout1, %{request: _request, status: NotAccepted} = state) do
    Process.send(self(), :block1, [:nosuspend])
    {:noreply, state}
  end

  def handle_info(:timeout1, %{request: _request, status: Accepted} = state) do
    {:noreply, state}
  end

  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, contacted_taxi: taxi} = state) do

    IO.inspect(state)


    if driver_username == taxi.nickname do
      %{
        "username" => customer_username
      } = request

      TaxiBeWeb.Endpoint.broadcast("customer:"<>customer_username, "booking_request", %{msg: "Tu taxi esta en camino"})
      # Process.send(self(), :block1, [:nosuspend])

      {:noreply, state |> Map.put(:status, Accepted)}
    else
      TaxiBeWeb.Endpoint.broadcast("driver:"<>driver_username, "booking_notification", %{msg: "Muy tarde para aceptar"})

      {:noreply, state}
    end



  end

  def handle_cast({:process_accept, driver_username}, %{request: request, status: Accepted} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:"<>driver_username, "booking_notification", %{msg: "Ha sido aceptado por otro socio"})
    # Process.send(self(), :block1, [:nosuspend])

    {:noreply, state}

  end

  def handle_cast({:process_reject, driver_username}, state) do
    # IO.inspect(state)
    Process.send(self(), :block1, [:nosuspend])
    {:noreply, state}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
     } = request

    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, Float.ceil(distance/300)}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Ride fare: #{fare}"})
  end

  def orderTaxis(pickup, taxis) do
    positions = taxis |> Enum.map(fn taxi -> [taxi.longitude, taxi.latitude] end)
    taxi_relative_positions = TaxiBeWeb.Geolocator.destination_and_duration(positions, pickup)
    finished_list =
      Enum.zip([taxis, taxi_relative_positions])
      |> Enum.sort(:desc)
      |> IO.inspect()
      |> Enum.map(fn {item, _} -> item end)

    finished_list
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368}, # Angelopolis
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737}, # Arcangeles
      %{nickname: "merry", latitude: 19.0092933, longitude: -98.2473716} # Paseo Destino
    ]
  end
end
