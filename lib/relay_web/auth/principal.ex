defmodule RelayWeb.Auth.Principal do
  @moduledoc """
  Who a verified credential speaks for: the scope it is bound to (tenant and environment, from the Access client record and never from the request), an optional sub-tenant, the granted scopes, the API client, an optional API client rate sub-limit (`%{"burst" => %{"weight" => n, "window_seconds" => s}}`), whether the token is bound to the connection's client certificate (RFC 8705), whether the credential is an agent's (a send then always records `sender_type: agent`, PC-57 (7)) and, for a subscriber token, the subscriber.
  """

  @enforce_keys [:scope, :scopes]
  defstruct [
    :scope,
    :scopes,
    subtenant_id: nil,
    api_client_id: nil,
    rate_limit: nil,
    certificate_bound: false,
    agent: false,
    subscriber_id: nil
  ]

  @type t :: %__MODULE__{
          scope: Relay.Scope.t(),
          scopes: [String.t()],
          subtenant_id: Relay.Id.t() | nil,
          api_client_id: String.t() | nil,
          rate_limit: %{optional(String.t()) => map()} | nil,
          certificate_bound: boolean(),
          agent: boolean(),
          subscriber_id: Relay.Id.t() | nil
        }
end
