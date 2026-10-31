defmodule Relay.Operators.Session do
  @moduledoc """
  An authenticated operator: a panel session resolved from its cookie, or the CLI's Access access token. It carries the operator's Access subject, its authentication and step-up state and its role grants, read from Relay's records on every request (TN-19, E-63).
  """

  @enforce_keys [:operator_id, :subject, :client_kind, :grants]
  defstruct [
    :id,
    :operator_id,
    :subject,
    :operator_created_at,
    :client_kind,
    :auth_time,
    :acr,
    :step_up_at,
    :step_up_ref,
    :access_session_ref,
    :csrf_digest,
    :expires_at,
    grants: []
  ]

  @type t :: %__MODULE__{
          id: Relay.Id.t() | nil,
          operator_id: Relay.Id.t(),
          subject: String.t(),
          operator_created_at: DateTime.t() | nil,
          client_kind: :panel | :cli,
          auth_time: DateTime.t() | nil,
          acr: String.t() | nil,
          step_up_at: DateTime.t() | nil,
          step_up_ref: String.t() | nil,
          access_session_ref: String.t() | nil,
          csrf_digest: binary() | nil,
          expires_at: DateTime.t() | nil,
          grants: [Relay.Operators.Authz.grant()]
        }
end
