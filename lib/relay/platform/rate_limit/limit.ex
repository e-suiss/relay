defmodule Relay.Platform.RateLimit.Limit do
  @moduledoc """
  A rate limit definition and its keys. The algorithm follows the use (T-19): `:gcra` for outbound channel and provider limits, `:fixed_window` only for long coarse quotas (a period of at least an hour), `:sliding_counter` for medium windows, `:sliding_log` for small per-recipient caps (`limit` at most 1000). Only a GCRA limit has a burst and only a GCRA limit can carry the cumulative lane ceiling.

  A key is the limit id followed by one to six parts in the order of T-20 (6): channel, provider account, tenant-internal components, target (the `target_key` hex). The tenant and environment come from the scope prefix and are not repeated. There is no global, keyless limiter: a key without parts is refused.

  Values stay below 2^53 so the Lua script, which computes in doubles, gives the same integers as Elixir and PostgreSQL.
  """

  alias Relay.Platform.RateLimit.Gcra

  @enforce_keys [:id, :algorithm, :unit, :limit, :period_ms]
  defstruct [:id, :algorithm, :unit, :limit, :period_ms, burst: nil, ceiling: false]

  @type algorithm :: :gcra | :fixed_window | :sliding_counter | :sliding_log
  @type unit :: :message | :recipient | :segment | :unique_recipient | :request
  @type t :: %__MODULE__{
          id: String.t(),
          algorithm: algorithm(),
          unit: unit(),
          limit: pos_integer(),
          period_ms: pos_integer(),
          burst: pos_integer() | nil,
          ceiling: boolean()
        }

  @algorithms [:gcra, :fixed_window, :sliding_counter, :sliding_log]
  @units [:message, :recipient, :segment, :unique_recipient, :request]
  @id ~r/\A[a-z][a-z0-9_.]{2,63}\z/
  @part ~r/\A[0-9A-Za-z_.\-]{1,128}\z/
  @max_parts 6
  @max_exact 9_007_199_254_740_991
  @hour_ms 3_600_000
  @max_log 1000

  # T-19
  # T-20 (6)
  # CH-17
  @doc "Builds a limit from its fields and checks the algorithm matrix of T-19."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(%{} = attrs) do
    limit =
      struct(
        __MODULE__,
        Map.take(attrs, [:id, :algorithm, :unit, :limit, :period_ms, :burst, :ceiling])
      )

    limit = %{limit | ceiling: Map.get(attrs, :ceiling, false)}

    case validate(limit) do
      :ok -> {:ok, limit}
      {:error, reason} -> {:error, Relay.Error.new(:invalid_limit, reason, %{id: limit.id})}
    end
  end

  @doc "Builds a limit and raises on an invalid definition."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, limit} -> limit
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate(%__MODULE__{} = l) do
    cond do
      not (is_binary(l.id) and Regex.match?(@id, l.id)) ->
        {:error, "invalid limit id"}

      l.algorithm not in @algorithms ->
        {:error, "unknown algorithm"}

      l.unit not in @units ->
        {:error, "unknown counting unit"}

      true ->
        validate_bounds(l)
    end
  end

  defp validate_bounds(%__MODULE__{} = l) do
    cond do
      not pos_int?(l.limit) or not pos_int?(l.period_ms) ->
        {:error, "limit and period must be positive"}

      not is_boolean(l.ceiling) ->
        {:error, "ceiling must be a boolean"}

      l.limit * l.period_ms * 1000 > @max_exact ->
        {:error, "limit times period exceeds 2^53"}

      true ->
        validate_algorithm(l)
    end
  end

  defp validate_algorithm(%__MODULE__{algorithm: :gcra} = l) do
    cond do
      not pos_int?(l.burst) ->
        {:error, "a GCRA limit needs a burst of at least 1"}

      l.burst * Gcra.emission_us(l.limit, l.period_ms) > @max_exact ->
        {:error, "burst exceeds 2^53"}

      true ->
        :ok
    end
  end

  defp validate_algorithm(%__MODULE__{} = l) do
    cond do
      l.burst != nil ->
        {:error, "only a GCRA limit has a burst"}

      l.ceiling ->
        {:error, "only a GCRA limit carries the lane ceiling"}

      l.algorithm == :fixed_window and l.period_ms < @hour_ms ->
        {:error, "a fixed window needs a period of at least one hour"}

      l.algorithm == :sliding_log and l.limit > @max_log ->
        {:error, "a sliding log allows at most 1000"}

      true ->
        :ok
    end
  end

  defp pos_int?(value), do: is_integer(value) and value > 0

  # T-20 (6)
  # CH-17
  @doc "Builds the limit key `<id>:<part_1>:…:<part_k>` from one to six parts."
  @spec key(t(), [String.t()]) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def key(%__MODULE__{id: id}, parts) when is_list(parts) do
    cond do
      parts == [] ->
        {:error, Relay.Error.new(:invalid_limit_key, "a limit key needs at least one part")}

      length(parts) > @max_parts ->
        {:error, Relay.Error.new(:invalid_limit_key, "a limit key has at most six parts")}

      not Enum.all?(parts, &(is_binary(&1) and Regex.match?(@part, &1))) ->
        {:error, Relay.Error.new(:invalid_limit_key, "invalid limit key part")}

      true ->
        {:ok, Enum.join([id | parts], ":")}
    end
  end

  def key(%__MODULE__{}, _parts),
    do: {:error, Relay.Error.new(:invalid_limit_key, "limit key parts must be a list")}

  # T-9 (5)
  @doc "How long a decision of this limit keeps affecting later ones, in milliseconds: the horizon a key stays dual after Valkey returns."
  @spec horizon_ms(t()) :: pos_integer()
  def horizon_ms(%__MODULE__{algorithm: :gcra} = l) do
    gcra = Gcra.ceil_div(l.burst * Gcra.emission_us(l.limit, l.period_ms), 1000)
    if l.ceiling, do: max(gcra, 2 * l.period_ms), else: gcra
  end

  def horizon_ms(%__MODULE__{algorithm: :sliding_counter, period_ms: p}), do: 2 * p
  def horizon_ms(%__MODULE__{period_ms: p}), do: p
end
