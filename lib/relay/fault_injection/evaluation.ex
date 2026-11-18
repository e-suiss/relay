defmodule Relay.FaultInjection.Evaluation do
  @moduledoc """
  The pure part of fault injection (OP-92): which records in force apply to a point of the delivery path. A record applies when it is in force (active and before its expiry, so an expired record is inert), its environment is the point's, its tenant is the point's or it covers the installation, and its channel and provider are the point's or unset (a point that names no channel or provider, such as a delivery report job, is matched by any). A record whose environment is `live` applies only while the node runs in chaos mode (`RELAY_CHAOS_MODE=true`); a record of the `test` environment always applies there. The draw against the record's rate is the caller's: `hit?/2` turns a number from 1 to 100 into the decision.
  """

  alias Relay.FaultInjection.Record

  @type point :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => Relay.Environment.t(),
          optional(:channel) => String.t() | nil,
          optional(:provider) => String.t() | nil
        }

  # OP-92
  # OP-49
  @doc "The first record of `kinds` that applies to `point` at `now`, or nil."
  @spec find([Record.t()], [Record.kind()], point(), DateTime.t(), boolean()) ::
          Record.t() | nil
  def find(records, kinds, point, now, chaos?) do
    Enum.find(records, &(&1.kind in kinds and applies?(&1, point, now, chaos?)))
  end

  # OP-92
  @doc "Returns true if `record` applies to `point` at `now`."
  @spec applies?(Record.t(), point(), DateTime.t(), boolean()) :: boolean()
  def applies?(%Record{} = record, point, now, chaos?) do
    Record.in_force?(record, now) and permitted?(record, chaos?) and
      record.target_environment == point.environment and
      (record.scope_kind == :installation or record.scope_tenant_id == point.tenant_id) and
      open?(record.channel, Map.get(point, :channel)) and
      open?(record.provider, Map.get(point, :provider))
  end

  # OP-92
  # OP-78
  @doc "Returns true if a record of `environment` may act on this node: always in `test`, in `live` only in chaos mode."
  @spec permitted?(Record.t() | Relay.Environment.t(), boolean()) :: boolean()
  def permitted?(%Record{target_environment: environment}, chaos?),
    do: permitted?(environment, chaos?)

  def permitted?(:test, _chaos?), do: true
  def permitted?(:live, chaos?), do: chaos? == true

  # OP-92
  @doc "Turns a draw from 1 to 100 into the decision of a record's rate: a rate of 0 never hits, 100 always."
  @spec hit?(Record.t(), 1..100) :: boolean()
  def hit?(%Record{rate_percent: rate}, draw) when draw in 1..100, do: draw <= rate

  defp open?(nil, _value), do: true
  defp open?(_wanted, nil), do: true
  defp open?(wanted, value), do: wanted == value
end
