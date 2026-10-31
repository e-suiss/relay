defmodule RelayWeb.Api.DerivedKey do
  @moduledoc """
  The idempotency key of a request to an operation whose contract says `x-relay-idempotency: derived` and that arrives without an `Idempotency-Key` header. A delivery with the shared Suiss webhook profile derives its key from its `webhook-id` (the Access event intake, S-69); a CloudEvents request derives its key from `(tenant, source, id)` of its event or of every event of a batch (API-31; the tenant and environment are the key's scope). Any other native JSON request without the header is `idempotency_key_missing`.
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

  def key(conn) do
    headers = for {"ce-" <> _ = name, value} <- conn.req_headers, do: {name, value}
    media = conn.assigns[:media_type]

    if media == "application/json" and not List.keymember?(headers, "ce-specversion", 0),
      do: :none,
      else: Relay.Api.CloudEvent.derived_key(media, conn.assigns[:body], headers)
  end
end
