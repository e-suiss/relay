defmodule Relay.Migration.Shadow do
  @moduledoc """
  Shadow comparison (OP-52, OP-79, OP-94). The existing system reports its decision for a request (`observe/2`); Relay's own decision for the same request is read from the deliveries of the events with the request's `correlation_id`, and what its shadow send would have sent is recorded when the channel step reaches the fake provider in shadow mode (`delivered/5`). Every side is masked or digested and sealed under the day key of `Relay.Migration.ShadowKeys`; the outcome of each comparison (its state, the layers that matched and the fields that differ) is kept in plain columns so the coverage report can count it without reading any sealed value. A comparison whose other side has not come within x-relay-limits `shadow.pending_grace` counts as a recipient set difference. Every function runs outside any transaction and opens its own.

  Telemetry: `[:relay, :shadow, :compared]` (`channel`, `state`) once a comparison leaves `pending`, and `[:relay, :shadow, :unpermitted]` (`channel`) when one side sent to a recipient whose consent the other side refused or suppressed.
  """

  require Logger

  alias Relay.Migration.Compare
  alias Relay.Migration.ShadowKeys
  alias Relay.Migration.Store
  alias Relay.Scope

  @window_days div(Relay.Limits.seconds!(["shadow", "retention"]), 86_400)
  @grace_s Relay.Limits.seconds!(["shadow", "pending_grace"])
  @min_comparisons Relay.Limits.fetch!(["shadow", "min_comparisons"])
  @min_observed_s Relay.Limits.seconds!(["shadow", "min_observed"])
  @settle_batch 50

  # OP-94
  # OP-52 (2)
  @doc "Records the existing system's report of one request and compares what can be compared now. Returns the counts of the answer."
  @spec observe(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def observe(%Scope{} = scope, observation) do
    correlation_id = observation["correlation_id"]

    with {:ok, key} <- ShadowKeys.today(scope),
         {:ok, located} <- locate(scope, observation),
         {known, unknown} = Enum.split_with(located, &match?({_entry, <<_::128>>}, &1)),
         :ok <- record_legacy(scope, key, observation, known),
         {:ok, compared} <- settle(scope, correlation_id) do
      {:ok,
       %{
         correlation_id: correlation_id,
         recorded: length(known),
         compared: compared,
         unknown_recipients: length(unknown)
       }}
    end
  end

  # OP-94
  # OP-52 (1)
  @doc "Records what a shadow send of a delivery would have sent, its content digest, the provider of its real route and its sender, and compares the request again. A delivery of an event without a correlation identifier records nothing. Never raises: shadow comparison never changes what the delivery does."
  @spec delivered(
          Scope.t(),
          Relay.Id.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def delivered(%Scope{} = scope, delivery_id, content_digest, provider, sender) do
    side = Compare.delivery_side(content_digest, provider, sender)

    with {:ok, %{} = request} <-
           Store.in_scope(scope, fn _status -> Store.delivery_request(delivery_id) end),
         {:ok, _recorded} <- record(scope, request, :delivery, side, nil),
         {:ok, _compared} <- settle(scope, request["correlation_id"]) do
      :ok
    else
      _none_or_error -> :ok
    end
  rescue
    exception ->
      Logger.warning("shadow delivery not recorded", error: Exception.message(exception))
      :ok
  end

  # OP-79
  # OP-94
  # OP-52 (6)
  @doc "The coverage report of the last 14 days per template, locale and channel, and whether the exit criterion holds; comparisons still waiting are compared again first."
  @spec coverage(Scope.t()) :: {:ok, map()} | {:error, term()}
  def coverage(%Scope{} = scope) do
    _ = settle_pending(scope)

    read = fn _status ->
      {Store.coverage(@window_days, @grace_s), Store.active_differences()}
    end

    with {:ok, {%{rows: rows, first_at: first_at}, active}} <- Store.in_scope(scope, read) do
      :telemetry.execute([:relay, :shadow, :differences], %{active: active})
      {:ok, report(rows, first_at, active, Relay.Clock.utc_now())}
    end
  end

  # OP-79
  @doc "The coverage report of counted rows: a row is sufficient with enough comparisons or once two full business cycles were observed, and the exit criterion needs every row sufficient, the cycles observed and no unexplained decision difference."
  @spec report([map()], DateTime.t() | nil, non_neg_integer(), DateTime.t()) :: map()
  def report(rows, first_at, active, %DateTime{} = now) do
    observed_s = if first_at, do: max(DateTime.diff(now, first_at), 0), else: 0
    cycles = first_at != nil and observed_s >= @min_observed_s

    rows =
      Enum.map(rows, fn row ->
        Map.put(row, "sufficient", row["observed"] >= @min_comparisons or cycles)
      end)

    unexplained = Enum.reduce(rows, 0, &(&1["unexplained"] + &2))
    sufficient = Enum.all?(rows, & &1["sufficient"])

    %{
      window_days: @window_days,
      first_observed_at: first_at,
      days_observed: div(observed_s, 86_400),
      cycles_met: cycles,
      unexplained_decision_differences: unexplained,
      active_intentional_differences: active,
      exit_criteria_met: rows != [] and cycles and unexplained == 0 and sufficient,
      rows: rows
    }
  end

  # OP-94
  @doc "Compares again the comparisons of a scope that still wait for Relay's decision, a bounded batch at a time; returns how many requests were looked at."
  @spec settle_pending(Scope.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def settle_pending(%Scope{} = scope) do
    with {:ok, rows} <-
           Store.in_scope(scope, fn _status -> Store.pending_comparisons(@settle_batch) end) do
      ids = rows |> Enum.map(& &1["correlation_id"]) |> Enum.uniq()
      Enum.each(ids, &settle(scope, &1))
      {:ok, length(ids)}
    end
  end

  defp locate(scope, observation) do
    entries =
      for channel <- observation["channels"], outcome <- channel["outcomes"] do
        {channel, outcome}
      end

    external_ids = entries |> Enum.map(fn {_channel, o} -> o["external_id"] end) |> Enum.uniq()

    found =
      Enum.reduce_while(external_ids, {:ok, %{}}, fn external_id, {:ok, acc} ->
        case Relay.Subscribers.locate(scope, external_id) do
          {:ok, id} -> {:cont, {:ok, Map.put(acc, external_id, id)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, ids} <- found do
      {:ok, Enum.map(entries, fn {_c, o} = entry -> {entry, Map.get(ids, o["external_id"])} end)}
    end
  end

  defp record_legacy(scope, key, observation, known) do
    Enum.reduce_while(known, :ok, fn {{channel, outcome}, recipient_id}, :ok ->
      request = %{
        "correlation_id" => observation["correlation_id"],
        "channel" => channel["channel"],
        "recipient_id" => recipient_id,
        "template_key" => observation["template"],
        "locale" => observation["locale"]
      }

      side = Compare.legacy_side(observation, channel, outcome)

      case record(scope, request, :legacy, side, key) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record(scope, request, side, values, key) do
    existing =
      Store.in_scope(scope, fn _status ->
        Store.comparison(request["correlation_id"], request["channel"], request["recipient_id"])
      end)

    with {:ok, row} <- existing,
         {:ok, key} <- key_for(scope, row, key),
         {:ok, ct} <- ShadowKeys.seal(scope, key, column(side), values) do
      attrs = %{
        id: Relay.Id.generate(),
        correlation_id: request["correlation_id"],
        channel: request["channel"],
        recipient_id: request["recipient_id"],
        key_id: key.id,
        side: side,
        template_key: request["template_key"],
        locale: request["locale"],
        ct: ct
      }

      Store.in_scope(scope, fn _status -> Store.shadow_side_record(attrs) end)
    end
  end

  defp key_for(_scope, %{"key_id" => key_id}, %{id: key_id} = key), do: {:ok, key}
  defp key_for(scope, %{"key_id" => key_id}, _key), do: ShadowKeys.fetch(scope, key_id)
  defp key_for(_scope, nil, %{id: _id} = key), do: {:ok, key}
  defp key_for(scope, nil, nil), do: ShadowKeys.today(scope)

  defp settle(_scope, nil), do: {:ok, 0}

  defp settle(scope, correlation_id) do
    read = fn _status ->
      {Store.relay_decisions(correlation_id), Store.comparisons(correlation_id)}
    end

    reread = fn _status -> Store.comparisons(correlation_id) end

    with {:ok, {decisions, rows}} <- Store.in_scope(scope, read),
         :ok <- record_relay(scope, correlation_id, decisions, rows),
         {:ok, rows} <- Store.in_scope(scope, reread) do
      {:ok, compare_rows(scope, rows)}
    end
  end

  defp record_relay(scope, correlation_id, decisions, rows) do
    recorded =
      for row <- rows, row["relay_ct"] != nil, into: MapSet.new() do
        {row["channel"], row["recipient_id"]}
      end

    decisions
    |> Enum.reject(&MapSet.member?(recorded, {&1["channel"], &1["recipient_id"]}))
    |> Enum.uniq_by(&{&1["channel"], &1["recipient_id"]})
    |> Enum.reduce_while(:ok, fn decision, :ok ->
      request = %{
        "correlation_id" => correlation_id,
        "channel" => decision["channel"],
        "recipient_id" => decision["recipient_id"],
        "template_key" => decision["template_key"],
        "locale" => decision["locale"]
      }

      case record(scope, request, :relay, Compare.relay_side(decision), nil) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compare_rows(scope, rows) do
    now = Relay.Clock.utc_now()

    Enum.count(rows, fn row -> compare_row(scope, row, now) == :compared end)
  end

  defp compare_row(scope, row, now) do
    case ShadowKeys.fetch(scope, row["key_id"]) do
      {:ok, key} ->
        legacy = ShadowKeys.unseal(scope, key, "legacy_ct", row["legacy_ct"])
        relay = ShadowKeys.unseal(scope, key, "relay_ct", row["relay_ct"])
        delivery = ShadowKeys.unseal(scope, key, "delivery_ct", row["delivery_ct"])
        final? = DateTime.diff(now, row["created_at"] || now) >= @grace_s
        outcome = Compare.compare(legacy, relay, delivery, final?)
        _ = Store.in_scope(scope, fn _status -> Store.shadow_compare_set(row["id"], outcome) end)
        if row["state"] == "pending", do: emit(row, outcome)
        if outcome.state == :pending, do: :waiting, else: :compared

      {:error, _unreadable} ->
        :waiting
    end
  end

  defp emit(_row, %{state: :pending}), do: :ok

  defp emit(row, outcome) do
    meta = %{channel: row["channel"]}
    compared = Map.put(meta, :state, outcome.state)
    :telemetry.execute([:relay, :shadow, :compared], %{count: 1}, compared)

    if outcome.unpermitted,
      do: :telemetry.execute([:relay, :shadow, :unpermitted], %{count: 1}, meta)

    :ok
  end

  defp column(:legacy), do: "legacy_ct"
  defp column(:relay), do: "relay_ct"
  defp column(:delivery), do: "delivery_ct"
end
