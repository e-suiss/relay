defmodule RelayWeb.TrackingController do
  @moduledoc false

  use RelayWeb, :controller

  @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")

  # CH-43
  # CH-44
  # DS-30
  @spec click(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def click(conn, %{"token" => token}) do
    case Relay.Engagement.click(token, request(conn)) do
      {:ok, url} ->
        conn
        |> put_resp_header("location", url)
        |> send_resp(302, "")

      {:error, :invalid} ->
        send_resp(conn, 404, "")

      {:error, :unavailable} ->
        send_resp(conn, 503, "")
    end
  end

  # DS-32
  @spec open(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.SendResp"]
  def open(conn, %{"token" => token}) do
    _ = Relay.Engagement.open(token, request(conn))

    conn
    |> put_resp_content_type("image/gif", nil)
    |> send_resp(200, @gif)
  end

  defp request(conn) do
    user_agent =
      case get_req_header(conn, "user-agent") do
        [value | _rest] -> value
        [] -> nil
      end

    %{
      method: conn.private[:relay_request_method] || conn.method,
      ip: conn.remote_ip,
      user_agent: user_agent,
      headers: conn.req_headers |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      at_ms: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)
    }
  end
end
