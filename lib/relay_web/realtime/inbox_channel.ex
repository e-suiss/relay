defmodule RelayWeb.Realtime.InboxChannel do
  @moduledoc """
  The `inbox` channel (IN-23, IN-26): the token subscriber's inbox stream, each envelope pushed with its event type as the event name. The join parameter `cursor` resumes after the last envelope `id` the client saw; without it the stream starts at the head with the current counters.

  The channel is read-only (IN-31): writes go through the REST API, and every client message is refused with `read_only`, except `auth.refresh` with a fresh subscriber token for the same subscriber, which moves the connection's expiry (INV-42). The stream's history is never queried over the channel (IN-32).
  """

  use Phoenix.Channel

  alias RelayWeb.Realtime.Session

  @cursor ~r/\A[\x21-\x7e]{1,512}\z/

  # IN-28
  # IN-32
  @impl true
  def join("inbox", params, socket) do
    %{grant: grant, token: token, device_id: device_id} = socket.assigns
    origin = Map.get(socket.assigns, :origin)

    with {:ok, cursor} <- cursor(params),
         {:ok, session, envelopes} <-
           Session.open(grant, token, cursor: cursor, device_id: device_id, origin: origin) do
      send(self(), {:relay_realtime_push, envelopes})
      {:ok, assign(socket, :session, session)}
    else
      {:error, %Relay.Error{code: code}} -> {:error, %{reason: Atom.to_string(code)}}
    end
  end

  # IN-31
  # INV-42
  @impl true
  def handle_in("auth.refresh", %{"token" => token}, socket) when is_binary(token) do
    case Session.refresh(socket.assigns.session, token) do
      {:ok, session} ->
        {:reply, :ok, assign(socket, :session, session)}

      {:error, %Relay.Error{code: code}} ->
        {:reply, {:error, %{reason: Atom.to_string(code)}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "read_only"}}, socket}

  # IN-24
  # IN-33
  @impl true
  def handle_info({:relay_realtime_push, envelopes}, socket),
    do: {:noreply, push_all(socket, envelopes)}

  def handle_info(message, socket) do
    case Session.handle(socket.assigns.session, message) do
      {:ok, session, envelopes} ->
        {:noreply, socket |> assign(:session, session) |> push_all(envelopes)}

      {:close, reason, session} ->
        send(socket.transport_pid, {:relay_realtime_close, Session.close_code(reason), reason})
        {:stop, {:shutdown, :closed}, assign(socket, :session, session)}

      :unknown ->
        {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{session: session} -> Session.close(session)
      _no_session -> :ok
    end
  end

  defp cursor(%{"cursor" => cursor}) when is_binary(cursor) do
    if Regex.match?(@cursor, cursor),
      do: {:ok, cursor},
      else: {:error, Relay.Error.new(:validation_failed, "cursor is not a stream cursor")}
  end

  defp cursor(%{"cursor" => nil}), do: {:ok, nil}
  defp cursor(%{"cursor" => _other}), do: cursor(%{"cursor" => ""})
  defp cursor(_params), do: {:ok, nil}

  defp push_all(socket, envelopes) do
    Enum.each(envelopes, &push(socket, &1["t"], &1))
    socket
  end
end
