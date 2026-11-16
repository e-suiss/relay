defmodule Relay.Webhooks.Health do
  @moduledoc """
  The health of one endpoint as the engine keeps it with the endpoint (WH-35, WH-36). The module is pure: it takes the stored health row, the time and the parameters, and returns the row to store and what follows from it.

  The circuit breaker is `Relay.Webhooks.Breaker`; its state lives in the columns `breaker_state`, `consecutive_failures`, `breaker_trips` and `breaker_retry_at`, the end of the open time or of the probe.

  The automatic disable counts an uninterrupted failure: `failing_since` is its first failed attempt and one successful delivery clears it. The clock starts (`failing_clock_at`) only once a failure follows another within `start_within_ms` and the first and the last failure lie at least `start_span_ms` apart. With the clock started the tenant is warned `warn_after_ms` after `failing_since` and the endpoint is disabled `disable_after_ms` after it.
  """

  alias Relay.Webhooks.Breaker
  alias Relay.Webhooks.Outcome

  @columns ~w(breaker_state breaker_opened_at breaker_open_seconds breaker_retry_at breaker_trips
              consecutive_failures failing_since failure_count last_failure_at last_failure_code
              last_response_status warned_at last_success_at last_attempt_at failing_clock_at)
  @states %{"closed" => :closed, "open" => :open, "half_open" => :half_open}

  @type row :: %{optional(String.t()) => term()}
  @type params :: %{
          breaker: Breaker.params(),
          start_within_ms: pos_integer(),
          start_span_ms: pos_integer(),
          warn_after_ms: pos_integer(),
          disable_after_ms: pos_integer()
        }
  @type effect :: :breaker_opened | :breaker_closed | :warn | :disable_failing | :disable_gone

  @doc "The health columns of a row, as `Relay.Webhooks.EngineStore.health_save/3` writes them."
  @spec columns(row()) :: row()
  def columns(row), do: Map.take(row, @columns)

  # WH-35
  @doc "The breaker of a stored health row."
  @spec breaker(row()) :: Breaker.t()
  def breaker(row) do
    state = Map.fetch!(@states, row["breaker_state"])
    until = ms(row["breaker_retry_at"])

    %Breaker{
      state: state,
      failures: row["consecutive_failures"],
      open_count: row["breaker_trips"],
      open_until: if(state == :open, do: until),
      probe_until: if(state == :half_open, do: until)
    }
  end

  # WH-35 (2)
  @doc "Admits an attempt at `now`: the breaker's decision and the row to store when it changed."
  @spec admit(row(), DateTime.t(), params()) :: {Breaker.decision(), row() | nil}
  def admit(row, %DateTime{} = now, params) do
    before = breaker(row)
    {decision, breaker} = Breaker.admit(before, ms(now), params.breaker)
    {decision, if(breaker != before, do: put_breaker(row, breaker, now, params))}
  end

  # WH-35
  # WH-36
  @doc "Records the result of an attempt that was admitted with `decision`; `auto_disable` is the endpoint's own setting. Returns the row to store and what follows."
  @spec record(row(), Outcome.t(), :allow | :probe, boolean(), DateTime.t(), params()) ::
          {row(), [effect()]}
  def record(row, %Outcome{} = outcome, decision, auto_disable, %DateTime{} = now, params) do
    before = breaker(row)
    breaker = recorded(before, outcome, decision, now, params)

    row =
      row
      |> put_breaker(breaker, now, params)
      |> Map.put("last_attempt_at", now)
      |> Map.put("last_response_status", outcome.status || row["last_response_status"])
      |> counted(outcome, now, params)

    effects =
      transition(before.state, breaker.state) ++
        gone(outcome) ++ due(row, auto_disable, now, params)

    {warned(row, effects, now), effects}
  end

  defp recorded(breaker, %Outcome{breaker: :neutral}, _decision, _now, _params), do: breaker

  defp recorded(breaker, %Outcome{breaker: result}, decision, now, params),
    do: Breaker.record(breaker, ms(now), params.breaker, decision, result)

  defp transition(:closed, :open), do: [:breaker_opened]
  defp transition(:half_open, :open), do: [:breaker_opened]
  defp transition(state, :closed) when state != :closed, do: [:breaker_closed]
  defp transition(_before, _after), do: []

  defp gone(%Outcome{endpoint: :disable}), do: [:disable_gone]
  defp gone(_outcome), do: []

  # WH-36 (1)
  defp counted(row, %Outcome{result: :delivered}, now, _params) do
    Map.merge(row, %{
      "failing_since" => nil,
      "failure_count" => 0,
      "failing_clock_at" => nil,
      "warned_at" => nil,
      "last_success_at" => now
    })
  end

  defp counted(row, %Outcome{result: :dead_lettered}, _now, _params), do: row

  defp counted(row, %Outcome{} = outcome, now, params) do
    since = row["failing_since"] || now
    previous = row["last_failure_at"]

    row
    |> Map.merge(%{
      "failing_since" => since,
      "failure_count" => row["failure_count"] + 1,
      "last_failure_at" => now,
      "last_failure_code" => code(outcome)
    })
    |> clock(previous, since, now, params)
  end

  defp clock(%{"failing_clock_at" => %DateTime{}} = row, _previous, _since, _now, _params),
    do: row

  defp clock(row, %DateTime{} = previous, since, now, params) do
    started? =
      row["failure_count"] > 1 and
        DateTime.diff(now, previous, :millisecond) <= params.start_within_ms and
        DateTime.diff(now, since, :millisecond) >= params.start_span_ms

    if started?, do: Map.put(row, "failing_clock_at", now), else: row
  end

  defp clock(row, _previous, _since, _now, _params), do: row

  # WH-36
  @doc "What the uninterrupted failure of a row asks for at `now`: a warning, the automatic disable, or nothing."
  @spec due(row(), boolean(), DateTime.t(), params()) :: [effect()]
  def due(%{"failing_clock_at" => %DateTime{}} = row, auto, now, params) do
    since = row["failing_since"]
    failing_ms = DateTime.diff(now, since, :millisecond)

    cond do
      auto and failing_ms >= params.disable_after_ms -> [:disable_failing]
      failing_ms >= params.warn_after_ms and row["warned_at"] == nil -> [:warn]
      true -> []
    end
  end

  def due(_row, _auto_disable, _now, _params), do: []

  defp warned(row, effects, now) do
    if :warn in effects, do: Map.put(row, "warned_at", now), else: row
  end

  # WH-36
  @doc "When the endpoint is disabled automatically if it keeps failing, or `nil` while the clock has not started or the endpoint opted out."
  @spec disable_at(row(), boolean(), params()) :: DateTime.t() | nil
  def disable_at(%{"failing_clock_at" => %DateTime{}, "failing_since" => since}, true, params),
    do: DateTime.add(since, params.disable_after_ms, :millisecond)

  def disable_at(_row, _auto_disable, _params), do: nil

  # WH-23
  @doc "The reason code of an outcome as the delivery log writes it."
  @spec code(Outcome.t()) :: String.t()
  def code(%Outcome{reason: :http_status, status: status}) when is_integer(status),
    do: "http_#{div(status, 100)}xx"

  def code(%Outcome{reason: :connection_error}), do: "connection_failed"
  def code(%Outcome{reason: :tls_error}), do: "tls_failed"
  def code(%Outcome{reason: :destination_blocked}), do: "address_blocked"
  def code(%Outcome{reason: reason}), do: Atom.to_string(reason)

  defp put_breaker(row, %Breaker{state: :closed} = breaker, _now, _params) do
    Map.merge(row, %{
      "breaker_state" => "closed",
      "breaker_opened_at" => nil,
      "breaker_open_seconds" => nil,
      "breaker_retry_at" => nil,
      "breaker_trips" => breaker.open_count,
      "consecutive_failures" => breaker.failures
    })
  end

  defp put_breaker(row, %Breaker{} = breaker, now, params) do
    until = if breaker.state == :half_open, do: breaker.probe_until, else: breaker.open_until
    seconds = div(Breaker.open_ms(max(breaker.open_count, 1), params.breaker), 1000)

    Map.merge(row, %{
      "breaker_state" => Atom.to_string(breaker.state),
      "breaker_opened_at" => row["breaker_opened_at"] || now,
      "breaker_open_seconds" => max(seconds, 1),
      "breaker_retry_at" => DateTime.from_unix!(until, :millisecond),
      "breaker_trips" => breaker.open_count,
      "consecutive_failures" => breaker.failures
    })
  end

  defp ms(nil), do: nil
  defp ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
end
