defmodule RelayWeb.Plugs.Correlation do
  @moduledoc false

  @behaviour Plug

  @header "correlation-id"
  @max_length 128

  # T-63
  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    id =
      case Plug.Conn.get_req_header(conn, @header) do
        [value | _] when byte_size(value) in 1..@max_length -> sanitize(value)
        _ -> nil
      end || generate()

    Logger.metadata(correlation_id: id)
    Plug.Conn.put_resp_header(conn, @header, id)
  end

  defp sanitize(value) do
    if value =~ ~r/\A[A-Za-z0-9_\-.:]+\z/, do: value, else: nil
  end

  defp generate, do: "cor_" <> Base.url_encode64(Relay.Random.bytes(16), padding: false)
end
