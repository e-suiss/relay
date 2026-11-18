defmodule Relay.FaultInjection.Record do
  @moduledoc """
  One fault injection record (OP-92): its scope (the installation or one tenant), the environment it targets, the optional channel and provider, the kind, the rate in percent, the delay of the two timed kinds, the reason, the creator, the expiry (at most one hour after it was written, OP-78) and the clear fields.
  """

  @enforce_keys [:id, :scope_kind, :target_environment, :kind, :rate_percent, :status]
  defstruct [
    :id,
    :scope_kind,
    :scope_tenant_id,
    :target_environment,
    :channel,
    :provider,
    :kind,
    :rate_percent,
    :delay_ms,
    :reason,
    :created_by_ref,
    :expires_at,
    :status,
    :cleared_at,
    :cleared_by_ref,
    :clear_reason,
    :created_at
  ]

  @type kind ::
          :provider_auth_error
          | :rate_limited_429
          | :concurrency_exhausted
          | :bounce_spike
          | :template_paused
          | :delayed_delivery_report
          | :iys_pull_stalled
          | :added_latency
  @type t :: %__MODULE__{
          id: Relay.Id.t(),
          scope_kind: :installation | :tenant,
          scope_tenant_id: Relay.Id.t() | nil,
          target_environment: Relay.Environment.t(),
          channel: String.t() | nil,
          provider: String.t() | nil,
          kind: kind(),
          rate_percent: 0..100,
          delay_ms: pos_integer() | nil,
          reason: String.t() | nil,
          created_by_ref: String.t() | nil,
          expires_at: DateTime.t() | nil,
          status: :active | :cleared,
          cleared_at: DateTime.t() | nil,
          cleared_by_ref: String.t() | nil,
          clear_reason: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @kinds ~w(provider_auth_error rate_limited_429 concurrency_exhausted bounce_spike
            template_paused delayed_delivery_report iys_pull_stalled added_latency)a
  @provider_kinds ~w(provider_auth_error rate_limited_429 concurrency_exhausted bounce_spike
                     template_paused added_latency)a

  # OP-92
  @doc "The kinds of a fault injection."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  # OP-92
  @doc "The kinds that act on the provider call."
  @spec provider_kinds() :: [kind(), ...]
  def provider_kinds, do: @provider_kinds

  @doc "Builds a record from a row map keyed by column name, as `relay_fn.fault_injection_list` returns it."
  @spec from_row(%{String.t() => term()}) :: t()
  def from_row(row) do
    {:ok, environment} = Relay.Environment.cast(row["target_environment"])

    %__MODULE__{
      id: row["id"],
      scope_kind: atom(row["scope_kind"], [:installation, :tenant]),
      scope_tenant_id: row["scope_tenant_id"],
      target_environment: environment,
      channel: row["channel"],
      provider: row["provider"],
      kind: atom(row["kind"], @kinds),
      rate_percent: row["rate_percent"],
      delay_ms: row["delay_ms"],
      reason: row["reason"],
      created_by_ref: row["created_by_ref"],
      expires_at: row["expires_at"],
      status: atom(row["status"], [:active, :cleared]),
      cleared_at: row["cleared_at"],
      cleared_by_ref: row["cleared_by_ref"],
      clear_reason: row["clear_reason"],
      created_at: row["created_at"]
    }
  end

  defp atom(nil, _allowed), do: nil

  defp atom(text, allowed) when is_binary(text),
    do: Enum.find(allowed, &(Atom.to_string(&1) == text)) || raise(ArgumentError, text)

  # OP-92
  @doc "Returns true if the record is in force at `now`: active and not past its expiry. An expired record is inert without being cleared."
  @spec in_force?(t(), DateTime.t()) :: boolean()
  def in_force?(%__MODULE__{status: :active, expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def in_force?(%__MODULE__{}, _now), do: false

  @doc "Returns the external identifier (`fij_…`) of a record identifier."
  @spec external_id(Relay.Id.t()) :: String.t()
  def external_id(id), do: Relay.ExternalId.encode("fij", id)
end
