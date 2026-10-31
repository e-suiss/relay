defmodule RelayWeb.Api.DerivedKey do
  @moduledoc """
  The idempotency key of a request to an operation whose contract says `x-relay-idempotency: derived` and that arrives without an `Idempotency-Key` header. A delivery with the shared Suiss webhook profile derives its key from its `webhook-id` (the Access event intake, S-69); a CloudEvents request derives its key from `(tenant, source, id)` (API-31) once that intake exists. Any other native JSON request without the header is `idempotency_key_missing`.
  """

  # API-10
  # API-31
  # E-36
  @doc "The derived key of a request, or `:none`."
  @spec key(Plug.Conn.t()) :: {:ok, String.t()} | :none
  def key(%{assigns: %{operation: %{security: :webhook}}} = conn) do
    case Plug.Conn.get_req_header(conn, "webhook-id") do
      [id | _] when byte_size(id) in 8..255 -> {:ok, id}
      _other -> :none
    end
  end

  def key(_conn), do: :none
end
