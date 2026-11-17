defmodule Relay.DestinationGuard do
  @moduledoc """
  The destination protections of `security` SMS (CH-54, E-33, TN-52): Relay's side of the OTP division of labour. The sender creates and verifies the code and sets its own account and flow limits; Relay protects the destinations. The channel step asks `admit/3` for every `security` SMS before it opens an attempt, whatever quota the notification was accepted under: the `security` reserve of an exhausted quota (TN-52 (1)) is no input here and can never pass a protection (TN-52 (2)).

  In order:

    1. Country allow-list. The number's country must be a country of the tenant's region or one the tenant added (`sms.security.allowed_countries`); otherwise the delivery is skipped with `destination.country_not_allowed`. A number without a country is never allowed.
    2. Stops. A destination under an active stop is skipped with `destination.country_stopped` or `destination.prefix_stopped`. A stop is a record; it never ends by itself and is lifted only by an explicit, audited action (`lift/4`).
    3. Rate limits, sliding windows counted once per delivery: per number (`destination.number_rate_limited`) and per number block (`destination.prefix_rate_limited`). A number over its limit is not counted to its block.
    4. Pumping detection. The sends counted to the number block and to the country in the detection window are compared with the tenant's own baseline for that destination (`Relay.DestinationGuard.Destination.anomaly?/3`); an anomaly opens a stop with `destination.pumping_prefix` or `destination.pumping_country`, its audit record and the `sms_destination.stopped` event in one transaction, and the delivery is skipped. When enough number blocks of one country were stopped within the escalation window the country is stopped too. A destination lifted within the grace period is not stopped again by the traffic counted before the lift.

  The detection is blind to verification outcomes: Relay never learns whether a code was used (INV-22), so it reads volume and concentration only.

  Everything fails closed (INV-43, F-11): when the allow-list, the stops or a counter cannot be read, `admit/3` returns an error, nothing is sent and nothing terminal is recorded; the job retries. The counters are sliding counters of `Relay.Platform.rate_counter/5`, which fall back to PostgreSQL when Valkey is away, so a Valkey loss alone stops no OTP. The values are the POLICY DEFAULT of `x-relay-limits` `sms_destination`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Audit, Relay.Platform], exports: []

  alias Relay.DestinationGuard.Destination
  alias Relay.DestinationGuard.Store
  alias Relay.Scope

  require Logger

  @limits ["sms_destination"]
  @block_digits Relay.Limits.fetch!(@limits ++ ["block_digits"])
  @number_limit Relay.Limits.fetch!(@limits ++ ["number_rate", "limit"])
  @number_window_ms Relay.Limits.seconds!(@limits ++ ["number_rate", "window"]) * 1000
  @prefix_limit Relay.Limits.fetch!(@limits ++ ["prefix_rate", "limit"])
  @prefix_window_ms Relay.Limits.seconds!(@limits ++ ["prefix_rate", "window"]) * 1000
  @window Relay.Limits.fetch!(@limits ++ ["pumping", "window"])
  @window_s Relay.Limits.seconds!(@limits ++ ["pumping", "window"])
  @baseline_s Relay.Limits.seconds!(@limits ++ ["pumping", "baseline_window"])
  @prefix_min Relay.Limits.fetch!(@limits ++ ["pumping", "prefix", "min_volume"])
  @prefix_multiplier Relay.Limits.fetch!(@limits ++ ["pumping", "prefix", "multiplier"])
  @country_min Relay.Limits.fetch!(@limits ++ ["pumping", "country", "min_volume"])
  @country_multiplier Relay.Limits.fetch!(@limits ++ ["pumping", "country", "multiplier"])
  @escalation_stops Relay.Limits.fetch!(@limits ++ ["pumping", "escalation", "prefix_stops"])
  @escalation_s Relay.Limits.seconds!(@limits ++ ["pumping", "escalation", "window"])
  @grace_s Relay.Limits.seconds!(@limits ++ ["pumping", "lift_grace"])
  @max_countries Relay.Limits.fetch!(@limits ++ ["max_allowed_countries"])
  @actor_ref "relay"
  @target "sms_destination_stop"

  @type request :: %{
          required(:number) => String.t(),
          required(:number_key) => String.t(),
          optional(:count?) => boolean()
        }
  @type decision :: :ok | {:skip, String.t()} | {:error, Relay.Error.t()}
  @type policy :: %{region: Relay.Region.t(), added: [String.t()]}
  @type counter :: (Scope.t(), String.t(), pos_integer(), atom(), non_neg_integer() -> term())
  @type option :: {:counter, counter()}

  # CH-54
  @doc "The POLICY DEFAULT values of the protections, as the contract's `x-relay-limits` `sms_destination` gives them."
  @spec limits() :: map()
  def limits do
    %{
      block_digits: @block_digits,
      number: %{limit: @number_limit, window_ms: @number_window_ms},
      prefix: %{limit: @prefix_limit, window_ms: @prefix_window_ms},
      pumping: %{
        window_s: @window_s,
        baseline_window_s: @baseline_s,
        prefix: detection(:prefix),
        country: detection(:country),
        escalation: %{prefix_stops: @escalation_stops, window_s: @escalation_s},
        lift_grace_s: @grace_s
      },
      max_allowed_countries: @max_countries
    }
  end

  defp detection(:prefix), do: detection(@prefix_min, @prefix_multiplier)
  defp detection(:country), do: detection(@country_min, @country_multiplier)

  defp detection(min_volume, multiplier) do
    %{
      min_volume: min_volume,
      multiplier: multiplier,
      window_s: @window_s,
      baseline_window_s: @baseline_s
    }
  end

  # CH-54
  # E-33
  # TN-52 (2)
  # INV-43
  @doc """
  Decides whether a `security` SMS may go to `number` (E.164). `number_key` is a keyed digest of the number as text, under which its counter is kept, so the number itself never becomes a counter key. With `count?: false` (a retry of a delivery that was already counted) the allow-list and the stops are checked and nothing is counted. Returns `:ok`, `{:skip, rule_id}` or, when an input could not be read, an error. `opts`: `:counter` replaces `Relay.Platform.rate_counter/5`.
  """
  @spec admit(Scope.t(), request(), [option()]) :: decision()
  def admit(%Scope{} = scope, %{number: number, number_key: key} = request, opts \\ [])
      when is_binary(number) and is_binary(key) do
    country = Destination.country(number)
    prefix = Destination.block(number, @block_digits)

    with {:ok, state} <- state(scope, country, prefix),
         :ok <- allowed(country, state.policy),
         :ok <- stopped(state.stops) do
      if Map.get(request, :count?, true),
        do: counted(scope, %{key: key, prefix: prefix, country: country}, opts),
        else: :ok
    end
  end

  defp state(scope, country, prefix) do
    read = fn _status ->
      %{
        policy: %{region: Store.region(), added: Store.added_countries()},
        stops: if(country, do: Store.match(country, [prefix]), else: [])
      }
    end

    with {:ok, %{policy: %{region: text} = policy} = state} <- Store.in_scope(scope, read),
         {:ok, region} <- Relay.Region.cast(text) do
      {:ok, %{state | policy: %{policy | region: region}}}
    else
      _unreadable -> unavailable(:policy)
    end
  end

  defp allowed(country, policy) do
    if Destination.allowed?(country, policy.region, policy.added),
      do: :ok,
      else: {:skip, "destination.country_not_allowed"}
  end

  defp stopped([]), do: :ok
  defp stopped([%{"kind" => "country"} | _rest]), do: {:skip, "destination.country_stopped"}
  defp stopped([_prefix | _rest]), do: {:skip, "destination.prefix_stopped"}

  defp counted(scope, destination, opts) do
    counter = Keyword.get(opts, :counter, &Relay.Platform.rate_counter/5)
    count = fn key, window_ms -> counter.(scope, key, window_ms, :incr, 1) end

    case count.("sms_destination:n:" <> destination.key, @number_window_ms) do
      {:ok, n} when n > @number_limit -> {:skip, "destination.number_rate_limited"}
      {:ok, _within} -> block_counted(scope, destination, count)
      {:error, _error} -> unavailable(:counter)
    end
  end

  defp block_counted(scope, %{prefix: "+" <> digits = prefix, country: country}, count) do
    day_ms = @baseline_s * 1000

    with {:ok, block} <- count.("sms_destination:p:" <> digits, @prefix_window_ms),
         {:ok, block_day} <- count.("sms_destination:pd:" <> digits, day_ms),
         {:ok, all} <- count.("sms_destination:c:" <> country, @window_s * 1000),
         {:ok, all_day} <- count.("sms_destination:cd:" <> country, day_ms) do
      found = [
        {:prefix, prefix, country, block, block_day},
        {:country, country, country, all, all_day}
      ]

      detect(scope, found, block)
    else
      {:error, _error} -> unavailable(:counter)
    end
  end

  defp detect(scope, found, block) do
    anomalies =
      for {kind, _value, _country, current, baseline} = one <- found,
          Destination.anomaly?(current, baseline, detection(kind)),
          do: one

    case Enum.reduce_while(anomalies, :none, &stop_anomaly(scope, &1, &2)) do
      {:skip, _rule_id} = skip -> skip
      {:error, _error} = error -> error
      :none when block > @prefix_limit -> {:skip, "destination.prefix_rate_limited"}
      :none -> :ok
    end
  end

  defp stop_anomaly(scope, {kind, value, country, current, baseline}, acc) do
    detail = %{
      "current" => current,
      "baseline" => baseline,
      "threshold" => Destination.threshold(baseline, detection(kind)),
      "window" => @window
    }

    rule_id = "destination.pumping_" <> Atom.to_string(kind)
    attrs = %{kind: kind, value: value, country: country, rule_id: rule_id, detail: detail}

    case stop(scope, attrs) do
      {:ok, {result, _id}} when result in [:opened, :exists] -> {:halt, skip(kind)}
      {:ok, {:recently_lifted, _id}} -> {:cont, acc}
      {:error, _error} -> {:halt, unavailable(:stop)}
    end
  end

  defp skip(:country), do: {:skip, "destination.country_stopped"}
  defp skip(:prefix), do: {:skip, "destination.prefix_stopped"}

  # CH-54
  # E-33
  @doc "Opens a stop of a number block (`kind: :prefix`, `value` its E.164 prefix) or a country (`kind: :country`, `value` its code) with the detection's `rule_id` and `detail`; `country` is the destination's country. The stop, its audit record and the tenant event commit together. A stop of a number block that makes its country reach the escalation count stops the country too. Returns `{:opened | :exists | :recently_lifted, id}`."
  @spec stop(Scope.t(), map()) ::
          {:ok, {:opened | :exists | :recently_lifted, Relay.Id.t() | nil}} | {:error, term()}
  def stop(%Scope{} = scope, %{kind: kind} = attrs) when kind in [:prefix, :country] do
    stop = Map.merge(attrs, %{id: Relay.Id.generate(), kind: Atom.to_string(kind)})

    opened =
      Store.in_scope(scope, fn _status ->
        Store.open(stop, @grace_s, @escalation_s, digest(scope, stop), actor())
      end)

    with {:ok, {result, id, prefix_stops}} <- opened do
      if result == :opened do
        :telemetry.execute([:relay, :destination_guard, :stopped], %{count: 1}, %{kind: kind})
        _ = escalate(scope, stop, prefix_stops)
      end

      {:ok, {result, id}}
    end
  end

  defp escalate(scope, %{kind: "prefix", country: country}, prefix_stops)
       when is_integer(prefix_stops) and prefix_stops >= @escalation_stops do
    stop(scope, %{
      kind: :country,
      value: country,
      country: country,
      rule_id: "destination.pumping_country",
      detail: %{"prefix_stops" => prefix_stops, "window" => @window}
    })
  end

  defp escalate(_scope, _stop, _prefix_stops), do: :ok

  defp digest(scope, stop) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: "sms_destination.stopped",
      actor_kind: "system",
      actor_ref: @actor_ref,
      on_behalf_of_ref: @actor_ref,
      access_record_ref: nil,
      target_type: @target,
      target_id: Relay.Id.to_string(stop.id),
      reason: stop.rule_id
    })
  end

  defp actor do
    {:ok, actor} = Relay.Actor.new(:system, @actor_ref, @actor_ref)
    actor
  end

  # CH-54
  @doc "Lifts a stop with a reason inside the caller's scoped transaction, with its audit record (`sms_destination.released`) and its tenant event; `digest` is the audit record digest."
  @spec lift(Relay.Id.t(), String.t(), binary(), Relay.Actor.t()) ::
          :lifted | :already_lifted | :not_found
  def lift(id, reason, digest, %Relay.Actor{} = actor), do: Store.lift(id, reason, digest, actor)

  # CH-54
  @doc "Reads a stop inside the caller's scoped transaction; `nil` when there is none."
  @spec stop_here(Relay.Id.t()) :: map() | nil
  def stop_here(id), do: Store.get(id)

  # CH-54
  @doc "Reads a stop; `nil` when there is none."
  @spec get_stop(Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_stop(%Scope{} = scope, id), do: Store.in_scope(scope, fn _status -> Store.get(id) end)

  # CH-54
  # API-56
  @doc "Lists stops newest first from a decoded cursor, optionally of one `state` (`active` or `lifted`); at most `limit + 1` rows come back."
  @spec list_stops(Scope.t(), String.t() | nil, map() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_stops(%Scope{} = scope, state, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.list(state, cursor, limit) end)

  # CH-54
  @doc "The allow-list of a scope: the countries of the tenant's region and the countries the tenant added."
  @spec allow_list(Scope.t()) ::
          {:ok, %{region_countries: [String.t()], allowed_countries: [String.t()]}}
          | {:error, term()}
  def allow_list(%Scope{} = scope) do
    read = fn _status -> {Store.region(), Store.added_countries()} end

    with {:ok, {text, added}} <- Store.in_scope(scope, read),
         {:ok, region} <- Relay.Region.cast(text) do
      {:ok, %{region_countries: Destination.region_countries(region), allowed_countries: added}}
    end
  end

  # CH-54
  @doc "The countries of the tenant's region inside the caller's scoped transaction; `[]` when the tenant cannot be read."
  @spec region_countries() :: [String.t()]
  def region_countries do
    case Relay.Region.cast(Store.region()) do
      {:ok, region} -> Destination.region_countries(region)
      {:error, _error} -> []
    end
  end

  @doc "The setting key of the countries a tenant added to its allow-list."
  @spec allow_list_key() :: String.t()
  defdelegate allow_list_key(), to: Store, as: :key

  # CH-54
  @doc "Returns true when a `security` SMS may go to `country` in a scope: the country is on the allow-list and not under an active stop. An input that cannot be read answers `false`."
  @spec open?(Scope.t(), String.t() | nil) :: boolean()
  def open?(%Scope{}, nil), do: false

  def open?(%Scope{} = scope, country) when is_binary(country) do
    case state(scope, country, "+00") do
      {:ok, %{policy: policy, stops: []}} ->
        Destination.allowed?(country, policy.region, policy.added)

      _closed_or_unreadable ->
        false
    end
  end

  @doc "The country of an E.164 number; see `Relay.DestinationGuard.Destination.country/1`."
  @spec country(String.t()) :: String.t() | nil
  defdelegate country(number), to: Destination

  @doc "Returns true when `number` is an E.164 number the protections can place; see `Relay.DestinationGuard.Destination.number?/1`."
  @spec number?(term()) :: boolean()
  defdelegate number?(number), to: Destination

  # INV-43
  defp unavailable(input) do
    :telemetry.execute([:relay, :destination_guard, :unavailable], %{count: 1}, %{input: input})
    Logger.error("destination protection input unavailable (#{input}); the send waits")
    {:error, Relay.Error.new(:service_unavailable, "destination protections unavailable")}
  end
end
