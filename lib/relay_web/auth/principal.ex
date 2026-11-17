defmodule RelayWeb.Auth.Principal do
  @moduledoc """
  Who a verified credential speaks for: its kind (`:api_client` for an Access machine credential, `:subscriber`, `:portal` or, for the console's operator session on a server operation, `:operator`, X-47), the scope it is bound to (tenant and environment, from the Access client record and never from the request; for an operator, the tenant context the session selected and its role grants allow), an optional sub-tenant, the granted scopes, the API client, an optional API client rate sub-limit (`%{"burst" => %{"weight" => n, "window_seconds" => s}}`), whether the token is bound to the connection's client certificate (RFC 8705), whether the credential is an agent's (a send then always records `sender_type: agent`, PC-57 (7)) with the agent recipient record its Access identity is bound to (E-29) and, for a subscriber token, the subscriber; for a webhook portal token, the one consumer it is scoped to (WH-47). An operator principal carries `operator`: the session, its highest role in the scope, the support delegation it acts under and the step-up references of the request.
  """

  @enforce_keys [:scope, :scopes]
  defstruct [
    :scope,
    :scopes,
    kind: :api_client,
    subtenant_id: nil,
    api_client_id: nil,
    rate_limit: nil,
    certificate_bound: false,
    agent: false,
    agent_id: nil,
    subscriber_id: nil,
    consumer_id: nil,
    operator: nil
  ]

  @type operator :: %{
          session: Relay.Operators.Session.t(),
          role: Relay.Operators.Authz.role(),
          delegation_id: Relay.Id.t() | nil,
          step_up_refs: %{step_up_ref: String.t(), decision_ref: String.t() | nil} | nil
        }

  @type t :: %__MODULE__{
          kind: :api_client | :subscriber | :portal | :operator,
          scope: Relay.Scope.t(),
          scopes: [String.t()],
          subtenant_id: Relay.Id.t() | nil,
          api_client_id: String.t() | nil,
          rate_limit: %{optional(String.t()) => map()} | nil,
          certificate_bound: boolean(),
          agent: boolean(),
          agent_id: Relay.Id.t() | nil,
          subscriber_id: Relay.Id.t() | nil,
          consumer_id: Relay.Id.t() | nil,
          operator: operator() | nil
        }
end
