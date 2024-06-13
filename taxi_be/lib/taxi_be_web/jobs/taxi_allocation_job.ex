defmodule TaxiBeWeb.TaxiAllocationJob do
  # tiempo de duracion de cada peticion a conductor: 15 segundos
  # Si se acaban los conductores avisa problema a cliente
  # Si en conductor tarda mas de 15 segundos, no es valida la aceptacion
  # correr mas de una vez si existe alguna falla en primer intento

  # igualemente se calcula el tiempo de llegada

  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  # incializa estado y manda a llamar step1
  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request}}
  end

  # notifica a cliente precio de viaje y agrega taxistas y status: NotAccepted a Estado
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

  # Manda notificacion de viaje disponible a cada taxista
  def handle_info(:block1, %{request: request, candidates: taxis, status: NotAccepted} = state) do
    # En caso de no agotar taxistas disponibles
    if taxis != [] do
      # extraer taxista mas cercano
      taxi = hd(taxis)
      # extraer datos del request
      %{
        "pickup_address" => pickup_address,
        "dropoff_address" => dropoff_address,
        "booking_id" => booking_id
      } = request

      # enviar notificacion al taxista
      TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
        %{
          msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
          bookingId: booking_id,
          status: true
      })

      # llamar funcion auxiliar de cancelacion de peticion a taxista cada 15 segundos
      Process.send_after(self(),:timeout1, 15000)

      # editar estado para descartar taxista notificado en el futuro
      {:noreply, %{request: request, candidates: tl(taxis), contacted_taxi: taxi, status: NotAccepted}}
    else
      # al agotar taxista
      %{
        "username" => customer_username
      } = request

      # notificar cliente de un problema buscando taxista disponible
      TaxiBeWeb.Endpoint.broadcast("customer:"<>customer_username, "booking_request", %{msg: "Hubo un problema"})
      {:noreply, %{state | contacted_taxi: ""}}
    end
  end

  # se manda a llamar anterior funcion pero con taxista anterior descartado
  def handle_info(:timeout1, %{request: _request, status: NotAccepted} = state) do
    Process.send(self(), :block1, [:nosuspend])
    {:noreply, state}
  end

  # En caso de que se mande a llamr cuando estado es Accepted, no se hace ninguna accion
  #  evita contactar nuevos taxista con peticion ya aceptada
  def handle_info(:timeout1, %{request: _request, status: Accepted} = state) do
    {:noreply, state}
  end

  # Aceptacion de taxista en caso NotAccepted
  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, contacted_taxi: taxi} = state) do
    # checar que el taxista que acepto coincide con contacted taxi
    if driver_username == taxi.nickname do
      # en caso de qeu si, hacer un procesode aceptacion exitosa
      %{
        "username" => customer_username,
        "pickup_address" => pickup
      } = request

      taxi = select_candidate_taxis(request)
      |> Enum.find(fn item -> item.nickname == driver_username end)

      arrival = compute_estimated_arrival(pickup, taxi)

      TaxiBeWeb.Endpoint.broadcast("customer:"<>customer_username, "booking_request", %{msg: "Your driver, #{driver_username} on the way in #{round(Float.floor(arrival/60, 0))} minutes and #{rem(round(arrival), 60)} seconds"})

      {:noreply, state |> Map.put(:status, Accepted)}
    else
      # en caso de que no, notificar al taxista que se tardo demasiado
      TaxiBeWeb.Endpoint.broadcast("driver:"<>driver_username, "booking_notification", %{msg: "Muy tarde para aceptar"})

      {:noreply, state}
    end



  end

  # aceptacion en estado Accepted
  def handle_cast({:process_accept, driver_username}, %{request: request, status: Accepted} = state) do
    # notificar al taxista que algun otro socio ya acepto esta solicitud
    TaxiBeWeb.Endpoint.broadcast("driver:"<>driver_username, "booking_notification", %{msg: "Ha sido aceptado por otro socio"})
    {:noreply, state}
  end

  # en caso de rechazo de un taxista no modifica estado ni hace llamadas para evitar
  # efectso secundarios en el proceso
  def handle_cast({:process_reject, driver_username}, state) do
    {:noreply, state}
  end

  # funciones auxiliarias para computar diferentes valores
  def compute_estimated_arrival(pickup_address, taxi) do
    coord1 = {:ok, [taxi.longitude, taxi.latitude]}
    coord2 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    {_distance, duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    duration
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
