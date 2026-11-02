defmodule Relay.Policy do
  @moduledoc """
  Message classes, preferences, consent, İYS and quiet hours: the gate, filter and scheduler lattice. Other contexts use only the functions of this module. The lattice is pure; its one backend, the frequency counter on Valkey, is the separate boundary `Relay.Policy.FrequencyCounter`.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Policy.Engine
  alias Relay.Policy.Frequency
  alias Relay.Policy.Priority
  alias Relay.Policy.Rules
  alias Relay.Policy.Snapshot
  alias Relay.Policy.Zone

  # PC-58 (1)
  @doc "Builds the input snapshot of one evaluation; see `Relay.Policy.Snapshot` for the fields."
  @spec snapshot!(map() | keyword()) :: Snapshot.t()
  def snapshot!(fields), do: Snapshot.new!(fields)

  # PC-8
  # PC-58 (1)
  # WF-41
  @doc "Evaluates the lattice for one delivery; see `Relay.Policy.Engine.evaluate/1`."
  @spec evaluate(Snapshot.t()) :: Engine.result()
  def evaluate(snapshot), do: Engine.evaluate(snapshot)

  # PC-58 (6)
  @doc "The frequency counters to read before evaluating a snapshot and to record after a send; see `Relay.Policy.Engine.counters/1`."
  @spec frequency_counters(Snapshot.t()) :: [Frequency.key()]
  def frequency_counters(snapshot), do: Engine.counters(snapshot)

  # PC-50
  # PC-58 (6)
  @doc "The frequency counters of a delivery of `class` on `channel` in a category, before a snapshot exists; see `Relay.Policy.Frequency.keys/5`."
  @spec frequency_keys(
          Snapshot.message_class(),
          Snapshot.channel(),
          String.t(),
          Snapshot.frequency_policy() | nil,
          pos_integer() | nil
        ) :: [Frequency.key()]
  def frequency_keys(class, channel, category_key, policy, global_cap),
    do: Frequency.keys(class, channel, category_key, policy, global_cap)

  # WF-45
  # PC-58 (4)
  @doc "Resolves a recipient's time zone and its source; see `Relay.Policy.Zone.resolve/4`."
  @spec resolve_time_zone(String.t() | nil, String.t() | nil, [String.t()] | nil, String.t()) ::
          {:ok, {Relay.TimeZone.t(), Zone.source()}} | :error
  def resolve_time_zone(profile_zone, device_zone, country_zones, tenant_zone),
    do: Zone.resolve(profile_zone, device_zone, country_zones, tenant_zone)

  # PC-58 (7)
  # API-22
  @doc "Clamps a requested priority to the class ceiling; see `Relay.Policy.Priority.clamp/2`."
  @spec clamp_priority(Snapshot.message_class(), Snapshot.priority() | nil) ::
          {Snapshot.priority(), boolean()}
  def clamp_priority(message_class, requested), do: Priority.clamp(message_class, requested)

  # DS-47 (4)
  @doc "Every rule id the lattice writes itself; see `Relay.Policy.Rules.ids/0`."
  @spec rule_ids() :: [String.t()]
  def rule_ids, do: Rules.ids()
end
