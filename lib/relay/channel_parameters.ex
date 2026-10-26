defmodule Relay.ChannelParameters do
  @moduledoc """
  The `channel_parameters` data set as a snapshot, and its pure lookups: retry backoff, circuit breaker parameters, failure weights, the retry budget, credit leases and lane ceilings (CH-69). The parameters are data, not code; a snapshot is built from the content of one active version and every lookup result carries that version's identifier, so a decision records the version it used (OP-65 (4)).

  A row whose key field is `nil` matches every value of that field. When several rows match, the most specific row wins: the one with the most non-`nil` key fields, and on a tie the one whose first non-`nil` field comes earlier in the order channel, provider, failure class, condition (CH-70). Ratios are basis points (10000 = 100 %) and durations are milliseconds.

  `validate/1` checks the rules a JSON Schema cannot express before a version is published.
  """

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)
  @classes ~w(transient permanent_target permanent_content policy quota auth sender_config unknown)
  @lanes ~w(l0 l1 l2 l3)

  @enforce_keys [:version_id]
  defstruct version_id: nil,
            backoff: [],
            breakers: [],
            failure_weights: [],
            retry_budgets: [],
            credit_leases: [],
            lane_ceilings: []

  @type text :: String.t() | atom() | nil
  @type row :: %{required(String.t()) => term()}
  @type level :: :tenant_provider | :provider
  @type t :: %__MODULE__{
          version_id: Relay.Id.t(),
          backoff: [row()],
          breakers: [row()],
          failure_weights: [row()],
          retry_budgets: [row()],
          credit_leases: [row()],
          lane_ceilings: [row()]
        }

  @doc "The failure classes that are never retried (INV-14)."
  @spec permanent_classes() :: [String.t(), ...]
  def permanent_classes, do: ~w(permanent_target permanent_content policy sender_config)

  # CH-69
  # OP-65 (4)
  @doc "Builds a snapshot from the content of a `channel_parameters` version and its identifier."
  @spec new(map(), Relay.Id.t()) :: t()
  def new(%{} = content, version_id) when is_binary(version_id) do
    %__MODULE__{
      version_id: version_id,
      backoff: Map.fetch!(content, "backoff"),
      breakers: Map.fetch!(content, "breakers"),
      failure_weights: Map.fetch!(content, "failure_weights"),
      retry_budgets: Map.fetch!(content, "retry_budgets"),
      credit_leases: Map.fetch!(content, "credit_leases"),
      lane_ceilings: Map.fetch!(content, "lane_ceilings")
    }
  end

  # CH-70
  # T-26
  @doc """
  Finds the backoff row of a failure. A `security` message first looks among the `security` rows and falls back to the rows without a message class. Returns `{:error, :missing}` when no row matches: then no retry is planned (CH-70).
  """
  @spec backoff(t(), text(), text(), text(), text(), text()) ::
          {:ok, row(), Relay.Id.t()} | {:error, :missing}
  def backoff(%__MODULE__{} = s, channel, provider, failure_class, condition, message_class) do
    input = %{
      "channel" => text(channel),
      "provider" => text(provider),
      "failure_class" => text(failure_class),
      "condition" => text(condition)
    }

    keys = ~w(channel provider failure_class condition)
    security = for row <- s.backoff, row["message_class"] == "security", do: row
    plain = for row <- s.backoff, row["message_class"] == nil, do: row

    candidates =
      if text(message_class) == "security",
        do: [most_specific(security, input, keys), most_specific(plain, input, keys)],
        else: [most_specific(plain, input, keys)]

    case Enum.find(candidates, & &1) do
      nil -> {:error, :missing}
      row -> {:ok, row, s.version_id}
    end
  end

  # T-25 (7)
  # CH-16
  @doc "Finds the circuit breaker row of a channel and provider; the common row always matches."
  @spec breaker(t(), text(), text()) :: {:ok, row(), Relay.Id.t()}
  def breaker(%__MODULE__{} = s, channel, provider) do
    input = %{"channel" => text(channel), "provider" => text(provider)}

    case most_specific(s.breakers, input, ~w(channel provider)) do
      nil -> raise ArgumentError, "channel_parameters has no common breaker row"
      row -> {:ok, row, s.version_id}
    end
  end

  # T-25 (3)
  # T-25 (4)
  @doc """
  Returns the breaker weight (1000 = 1.0) of a failure and the breaker level it counts towards. A condition without its own row uses the class's row without a condition; a class with neither counts with its heaviest condition.
  """
  @spec weight(t(), text(), text()) :: {non_neg_integer(), level()}
  def weight(%__MODULE__{} = s, failure_class, condition) do
    class = text(failure_class)
    rows = for row <- s.failure_weights, row["failure_class"] == class, do: row

    row =
      Enum.find(rows, &(&1["condition"] == text(condition))) ||
        Enum.find(rows, &(&1["condition"] == nil)) ||
        heaviest(rows, class)

    {row["weight_milli"], level(row["level"])}
  end

  defp heaviest([], class),
    do: raise(ArgumentError, "channel_parameters has no weight for #{inspect(class)}")

  defp heaviest(rows, _class), do: Enum.max_by(rows, & &1["weight_milli"])

  # T-27
  @doc "Finds the retry budget row of a channel, falling back to the row for every channel."
  @spec retry_budget(t(), text()) :: {:ok, row(), Relay.Id.t()}
  def retry_budget(%__MODULE__{} = s, channel) do
    row =
      Enum.find(s.retry_budgets, &(&1["channel"] == text(channel))) ||
        Enum.find(s.retry_budgets, &(&1["channel"] == nil)) ||
        raise ArgumentError, "channel_parameters has no common retry budget row"

    {:ok, row, s.version_id}
  end

  # T-20 (5)
  @doc "Returns whether a channel may lease credit blocks and the block size."
  @spec credit_lease(t(), text()) :: {boolean(), pos_integer() | nil}
  def credit_lease(%__MODULE__{} = s, channel) do
    case Enum.find(s.credit_leases, &(&1["channel"] == text(channel))) do
      nil -> {false, nil}
      row -> {row["allowed"], row["block_size"]}
    end
  end

  # T-33
  @doc "Returns the cumulative ceiling of a lane, in basis points of the limit."
  @spec lane_ceiling(t(), text()) :: pos_integer()
  def lane_ceiling(%__MODULE__{} = s, lane) do
    case Enum.find(s.lane_ceilings, &(&1["lane"] == text(lane))) do
      nil -> raise ArgumentError, "channel_parameters has no ceiling for lane #{inspect(lane)}"
      row -> row["ceiling_bp"]
    end
  end

  # CH-69
  # CH-70
  # T-20 (5)
  # T-33
  @doc """
  Checks the rules of a `channel_parameters` version that its JSON Schema cannot express: no two rows with the same key; the four lanes once each, `l0` at 10000 and the ceilings not increasing from `l0` to `l3`; a common breaker row; a weight for every failure class; a retry budget for every channel; one credit lease row per channel with no lease for SMS; and a backoff cap not below its base.
  """
  @spec validate(map()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{} = content) do
    checks = [
      unique_backoff:
        unique?(content, "backoff", ~w(channel provider failure_class condition message_class)),
      unique_breakers: unique?(content, "breakers", ~w(channel provider)),
      unique_weights: unique?(content, "failure_weights", ~w(failure_class condition)),
      unique_retry_budgets: unique?(content, "retry_budgets", ~w(channel)),
      lane_ceilings: lane_ceilings?(Map.get(content, "lane_ceilings", [])),
      common_breaker:
        Enum.any?(rows(content, "breakers"), &(&1["channel"] == nil and &1["provider"] == nil)),
      every_class_weighted:
        MapSet.subset?(
          MapSet.new(@classes),
          MapSet.new(rows(content, "failure_weights"), & &1["failure_class"])
        ),
      common_retry_budget: Enum.any?(rows(content, "retry_budgets"), &(&1["channel"] == nil)),
      credit_leases: credit_leases?(rows(content, "credit_leases")),
      backoff_cap: Enum.all?(rows(content, "backoff"), &cap?/1)
    ]

    case Enum.find(checks, fn {_rule, ok?} -> not ok? end) do
      nil ->
        :ok

      {rule, false} ->
        {:error,
         Relay.Error.new(:invalid_content, "channel_parameters breaks a consistency rule", %{
           rule: rule
         })}
    end
  end

  defp rows(content, key) do
    case Map.get(content, key) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp unique?(content, key, fields) do
    keys = Enum.map(rows(content, key), fn row -> Enum.map(fields, &Map.get(row, &1)) end)
    length(keys) == length(Enum.uniq(keys))
  end

  defp lane_ceilings?(rows) do
    by_lane = Map.new(rows, &{&1["lane"], &1["ceiling_bp"]})
    values = Enum.map(@lanes, &Map.get(by_lane, &1))

    length(rows) == 4 and Enum.sort(Map.keys(by_lane)) == @lanes and
      hd(values) == 10_000 and values == Enum.sort(values, :desc)
  end

  defp credit_leases?(rows) do
    channels = Enum.map(rows, & &1["channel"])

    Enum.sort(channels) == Enum.sort(@channels) and
      Enum.all?(rows, &(&1["channel"] != "sms" or &1["allowed"] == false))
  end

  defp cap?(%{"mode" => "exponential", "base_ms" => base, "cap_ms" => cap})
       when is_integer(base) and is_integer(cap),
       do: cap >= base

  defp cap?(_row), do: true

  defp most_specific(rows, input, keys) do
    rows
    |> Enum.filter(fn row -> Enum.all?(keys, &(row[&1] == nil or row[&1] == input[&1])) end)
    |> Enum.max_by(&specificity(&1, keys), fn -> nil end)
  end

  defp specificity(row, keys) do
    bits = Enum.map(keys, &if(row[&1] == nil, do: 0, else: 1))
    {Enum.sum(bits), bits}
  end

  defp level("tenant_provider"), do: :tenant_provider
  defp level("provider"), do: :provider

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
end
