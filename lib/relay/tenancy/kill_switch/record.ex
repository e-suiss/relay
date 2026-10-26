defmodule Relay.Tenancy.KillSwitch.Record do
  @moduledoc """
  One kill switch record (TN-36): its scope, channel, target, message class and state, with the reason, the creator, the expiry and the release fields. A `paused_until` state whose time is `nil` pauses without end; only the dead-man switch writes such a record (S-53).
  """

  @enforce_keys [:id, :tenant_id, :environment, :scope_kind, :target_kind, :state, :status]
  defstruct [
    :id,
    :tenant_id,
    :environment,
    :scope_kind,
    :scope_ref,
    :channel,
    :target_kind,
    :target_ref,
    :message_class,
    :security_approval_ref,
    :state,
    :canary_percent,
    :paused_until,
    :reason,
    :ticket_ref,
    :origin,
    :created_by_ref,
    :expires_at,
    :no_ttl_approval_ref,
    :supersedes_id,
    :status,
    :released_at,
    :released_by_ref,
    :release_reason,
    :release_approval_ref,
    :created_at
  ]

  @type scope_kind ::
          :platform | :tenant | :subtenant | :campaign | :workflow | :api_client | :sender
  @type state :: :on | :off | :canary | :paused_until
  @type t :: %__MODULE__{
          id: Relay.Id.t(),
          tenant_id: Relay.Id.t(),
          environment: Relay.Environment.t(),
          scope_kind: scope_kind(),
          scope_ref: String.t() | nil,
          channel: String.t() | nil,
          target_kind: :all | :provider_account | :template,
          target_ref: String.t() | nil,
          message_class: String.t() | nil,
          security_approval_ref: String.t() | nil,
          state: state(),
          canary_percent: 1..99 | nil,
          paused_until: DateTime.t() | nil,
          reason: String.t() | nil,
          ticket_ref: String.t() | nil,
          origin: :operator | :dead_man | nil,
          created_by_ref: String.t() | nil,
          expires_at: DateTime.t() | nil,
          no_ttl_approval_ref: String.t() | nil,
          supersedes_id: Relay.Id.t() | nil,
          status: :active | :released,
          released_at: DateTime.t() | nil,
          released_by_ref: String.t() | nil,
          release_reason: String.t() | nil,
          release_approval_ref: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @scope_kinds ~w(platform tenant subtenant campaign workflow api_client sender)a
  @target_kinds ~w(all provider_account template)a
  @states ~w(on off canary paused_until)a

  @doc "Scope kinds of a kill switch."
  @spec scope_kinds() :: [scope_kind(), ...]
  def scope_kinds, do: @scope_kinds

  @doc "States of a kill switch."
  @spec states() :: [state(), ...]
  def states, do: @states

  @doc "Builds a record from a row map keyed by column name, as `kill_switch_snapshot` and `kill_switch_list` return it."
  @spec from_row(%{String.t() => term()}) :: t()
  def from_row(row) do
    {:ok, environment} = Relay.Environment.cast(row["environment"])

    %__MODULE__{
      id: row["id"],
      tenant_id: row["tenant_id"],
      environment: environment,
      scope_kind: atom(row["scope_kind"], @scope_kinds),
      scope_ref: row["scope_ref"],
      channel: row["channel"],
      target_kind: atom(row["target_kind"], @target_kinds),
      target_ref: row["target_ref"],
      message_class: row["message_class"],
      security_approval_ref: row["security_approval_ref"],
      state: atom(row["state"], @states),
      canary_percent: row["canary_percent"],
      paused_until: row["paused_until"],
      reason: row["reason"],
      ticket_ref: row["ticket_ref"],
      origin: atom(row["origin"], [:operator, :dead_man]),
      created_by_ref: row["created_by_ref"],
      expires_at: row["expires_at"],
      no_ttl_approval_ref: row["no_ttl_approval_ref"],
      supersedes_id: row["supersedes_id"],
      status: atom(row["status"], [:active, :released]),
      released_at: row["released_at"],
      released_by_ref: row["released_by_ref"],
      release_reason: row["release_reason"],
      release_approval_ref: row["release_approval_ref"],
      created_at: row["created_at"]
    }
  end

  defp atom(nil, _allowed), do: nil

  defp atom(text, allowed) when is_binary(text),
    do: Enum.find(allowed, &(Atom.to_string(&1) == text)) || raise(ArgumentError, text)

  @doc "Returns true if the record is in force at `now`: active and not past its expiry."
  @spec in_force?(t(), DateTime.t()) :: boolean()
  def in_force?(%__MODULE__{status: :active, expires_at: nil}, _now), do: true

  def in_force?(%__MODULE__{status: :active, expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def in_force?(%__MODULE__{}, _now), do: false

  @doc "Returns the external identifier (`ksw_…`) of a record identifier."
  @spec external_id(Relay.Id.t()) :: String.t()
  def external_id(id), do: Relay.ExternalId.encode("ksw", id)
end
