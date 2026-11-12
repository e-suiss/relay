defmodule RelayWeb.Realtime.Socket do
  @moduledoc """
  The subscriber's Phoenix socket (IN-23). The client sends its Relay subscriber token as the channels client's `authToken` (the `Sec-WebSocket-Protocol` header); a token in the URL is not read. The socket carries one channel, `inbox`, whose stream the token decides (IN-32): the topic names neither the tenant nor the subscriber, and any other topic is refused. The optional `device_id` connect parameter names the subscriber's device for IN-40.
  """

  use Phoenix.Socket

  alias Relay.Realtime.Connections
  alias RelayWeb.Realtime.Authorization

  channel "inbox", RelayWeb.Realtime.InboxChannel

  # IN-32
  # IN-33
  # E-25
  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    with {:ok, device_id} <- device(params),
         {:ok, grant} <- Authorization.authorize(Map.get(connect_info, :auth_token)) do
      token = Map.fetch!(connect_info, :auth_token)
      {:ok, assign(socket, grant: grant, token: token, device_id: device_id)}
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil

  defp device(%{"device_id" => device_id}) do
    if Connections.device?(device_id),
      do: {:ok, device_id},
      else: {:error, Relay.Error.new(:validation_failed, "device_id is not a device identifier")}
  end

  defp device(_params), do: {:ok, nil}
end
