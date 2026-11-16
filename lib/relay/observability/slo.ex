defmodule Relay.Observability.Slo do
  @moduledoc """
  The SLO table, one per message class, read at compile time from `priv/observability/slo.json`; it is the single source of the targets, the burn rate windows, the proven delivery drop alarm and the kill switch effect target, and the Prometheus rules in `deploy/observability/alerts.yaml` are checked against it. Each class has an accept latency threshold, a provider handoff latency threshold (deferrals for quiet hours, frequency caps, `send_at` and provider limits are not counted) and an availability target; the latency SLIs are threshold SLIs, the share of events within the threshold, with the table's latency objective.
  """

  @path Path.expand("../../../priv/observability/slo.json", __DIR__)
  @external_resource @path

  @table @path |> File.read!() |> Jason.decode!()
  @names Map.new(
           ~w(security action_required transactional operational system social marketing)a,
           &{Atom.to_string(&1), &1}
         )
  @classes Map.new(@table["classes"], &{Map.fetch!(@names, &1["class"]), &1})

  @type class ::
          :security
          | :action_required
          | :transactional
          | :operational
          | :system
          | :social
          | :marketing

  # DS-42
  # OP-36
  @doc "The whole table as the data file writes it."
  @spec table() :: map()
  def table, do: @table

  # DS-42
  @doc "The message classes of the table."
  @spec classes() :: [class(), ...]
  def classes, do: Enum.map(@table["classes"], &Map.fetch!(@names, &1["class"]))

  # DS-42
  # OP-36 (2)
  @doc "The accept latency threshold of a class in milliseconds."
  @spec accept_ms(class()) :: pos_integer()
  def accept_ms(class), do: Map.fetch!(@classes, class)["accept_ms"]

  # DS-42
  # OP-36 (2)
  @doc "The provider handoff latency threshold of a class in milliseconds."
  @spec handoff_ms(class()) :: pos_integer()
  def handoff_ms(class), do: Map.fetch!(@classes, class)["handoff_ms"]

  # DS-42
  # OP-36 (1)
  @doc "The availability target of a class: the share of attempts the provider accepts."
  @spec availability(class()) :: float()
  def availability(class), do: Map.fetch!(@classes, class)["availability"]

  # OP-36 (2)
  @doc "The objective of the latency SLIs: the share of events that stay within the threshold."
  @spec latency_objective() :: float()
  def latency_objective, do: @table["latency_objective"]

  # OP-36 (3)
  @doc "The multi-window burn rate alarms: name, long and short window, factor and severity."
  @spec burn_rates() :: [map(), ...]
  def burn_rates, do: @table["burn_rates"]

  # OP-36 (5)
  @doc "The proven delivery drop alarm: the drop, its window and the minimum deliveries per window."
  @spec proven_delivery_drop() :: map()
  def proven_delivery_drop, do: @table["proven_delivery_drop"]

  # TN-44
  @doc "The kill switch effect target: seconds from the stop to the last message out."
  @spec kill_switch_effect_seconds() :: pos_integer()
  def kill_switch_effect_seconds, do: @table["kill_switch_effect_seconds"]

  # OP-37 (1)
  # OP-37 (3)
  @doc "The oldest job age alarm threshold of a lane in seconds: the strictest handoff threshold of the classes the lane carries."
  @spec queue_age_seconds(:l0 | :l1 | :l2 | :l3) :: pos_integer()
  def queue_age_seconds(lane) do
    classes()
    |> Enum.filter(&(Relay.Platform.lane(&1) == lane))
    |> Enum.map(&handoff_ms/1)
    |> Enum.min()
    |> div(1000)
  end

  # DS-42
  # OP-36 (2)
  @doc "True when an accept of the class took at most its threshold."
  @spec accept_good?(class(), non_neg_integer()) :: boolean()
  def accept_good?(class, duration_ms), do: duration_ms <= accept_ms(class)

  # DS-42
  # OP-36 (2)
  @doc "True when a handoff of the class took at most its threshold."
  @spec handoff_good?(class(), non_neg_integer()) :: boolean()
  def handoff_good?(class, duration_ms), do: duration_ms <= handoff_ms(class)
end
