defmodule RelayWeb.AccessEventController do
  @moduledoc false

  use RelayWeb, :controller

  @media "application/secevent+jwt"
  @max_bytes 65_536

  # E-94
  # sobelow_skip ["XSS.SendResp"]
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    with :ok <- media(conn),
         {:ok, token, conn} <- read_body(conn, length: @max_bytes) do
      answer(conn, Relay.Access.accept_event(String.trim_trailing(token)))
    else
      :unsupported -> send_resp(conn, 415, "")
      {:more, _partial, conn} -> refuse(conn, "invalid_request", "the SET exceeds 65536 bytes")
      {:error, _reason} -> refuse(conn, "invalid_request", "the body could not be read")
    end
  end

  defp media(conn) do
    with [value] <- get_req_header(conn, "content-type"),
         {:ok, type, subtype, _params} <- Plug.Conn.Utils.content_type(value),
         true <- type <> "/" <> subtype == @media do
      :ok
    else
      _other -> :unsupported
    end
  end

  defp answer(conn, :ok), do: send_resp(conn, 202, "")
  defp answer(conn, {:error, {:refused, err, description}}), do: refuse(conn, err, description)
  defp answer(conn, {:error, %Relay.Error{}}), do: send_resp(conn, 503, "")

  defp refuse(conn, err, description),
    do: conn |> put_status(400) |> json(%{"err" => err, "description" => description})
end
