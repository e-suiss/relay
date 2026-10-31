defmodule RelayWeb.Api.ErrorCodeController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.ErrorCatalog
  alias RelayWeb.Api.Response

  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # API-73
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"code" => code}) do
    with true <- Regex.match?(@code, code),
         {:ok, entry} <- ErrorCatalog.fetch(code) do
      Response.json(conn, 200, ErrorCatalog.describe(entry, Response.base_url()))
    else
      _ -> Response.problem(conn, Relay.Error.new(:error_code_not_found, "no such error code"))
    end
  end
end
