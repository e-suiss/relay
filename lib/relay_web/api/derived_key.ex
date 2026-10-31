defmodule RelayWeb.Api.DerivedKey do
  @moduledoc """
  The idempotency key of a request to an operation whose contract says `x-relay-idempotency: derived` and that arrives without an `Idempotency-Key` header. A CloudEvents request derives its key from `(tenant, source, id)` (API-31); until that intake exists no request derives a key, so a native JSON request without the header is `idempotency_key_missing`.
  """

  # API-10
  # API-31
  @doc "The derived key of a request, or `:none`."
  @spec key(Plug.Conn.t()) :: {:ok, String.t()} | :none
  def key(_conn), do: :none
end
