defmodule Relay.Policy.Live do
  @moduledoc """
  The policy lattice at run time (PC-58 (2), TN-70 (2)): it reads the input snapshot of one delivery from the database, adds the frequency readings, evaluates the pure lattice (`Relay.Policy.evaluate/1`) and records the decision. It runs in three places: when a delivery is opened at acceptance (`decide/1` and `record/2`, inside the accepting transaction), on every run of the delivery job (`job/2`, PC-8) and when a kill switch or a suspension resumes a paused delivery (`reevaluate/1`, the `Relay.Policy.Lattice` port, TN-40).

  Every skip and expiry is recorded on the delivery with its reason, rule and detail, with a ledger event and a `notification.suppressed` outbox event in the same transaction; a deferral is a `delivery.deferred` ledger event and the delivery stays `queued` with `deferred_until` (DS-24, DS-26, DS-27). An input that cannot be read records nothing and the job retries (INV-43); only the frequency counter fails open (INV-45). At acceptance and in the job, a deferral by quiet hours of a `social` or `marketing` delivery, a frequency cap met with the `digest` fate and a send past the category's density threshold hold the delivery in a digest window instead (`Relay.Policy.Live.Hold`, PC-46, PC-50, WF-30): it is recorded as deferred with its digest rule until the window fires and its job ends; the window's release (`digest_ready/2`, configured as `config :relay, Relay.Workflow.Digest, release: Relay.Policy.Live`) queues it again. Counters are read outside every transaction and counted only for a delivery the lattice sends, by its identifier. Each recorded decision emits `[:relay, :policy, :decision]` telemetry with its kind and reason. `config :relay, Relay.Policy.Live, frequency_counter: […]` passes options to `Relay.Policy.FrequencyCounter`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Delivery,
      Relay.Devices,
      Relay.Policy,
      Relay.Policy.FrequencyCounter,
      Relay.Policy.Lattice,
      Relay.Tenancy.KillSwitch,
      Relay.Workflow
    ],
    exports: []

  @behaviour Relay.Policy.Lattice

  alias Relay.Policy.FrequencyCounter
  alias Relay.Policy.Live.Hold
  alias Relay.Policy.Live.Inputs
  alias Relay.Policy.Live.Store
  alias Relay.Scope
  alias Relay.Tenancy.KillSwitch

  @hour 3_600_000
  @class_expires %{
    transactional: 6 * @hour,
    operational: 24 * @hour,
    social: 48 * @hour,
    marketing: 48 * @hour,
    action_required: 24 * @hour,
    system: @hour
  }

  @type result :: term()
  @type job_result ::
          {:send, map()}
          | {:defer, DateTime.t()}
          | :held
          | :done
          | {:error, {:input_unavailable, atom()}}

  # PC-57 (1)
  # PC-57 (2)
  # PC-57 (3)
  @doc "Reads the category of `key` with the setting of `subtenant_id` in its own read transaction; a key without a category row has the class defaults of `class`."
  @spec category(Scope.t(), String.t(), atom(), Relay.Id.t() | nil) ::
          {:ok, Inputs.category()} | {:error, term()}
  def category(%Scope{} = scope, key, class, subtenant_id) do
    Store.in_scope(scope, fn _status ->
      Inputs.category(Store.category(key, subtenant_id), key, class)
    end)
  end

  # PC-49
  # PC-57 (4)
  @doc "The default `expires_at` of a delivery that gives none, counted from `from`: the category's `default_expires_in`, otherwise the class default; `security` has no default."
  @spec default_expires_at(Inputs.category(), atom(), DateTime.t()) :: DateTime.t() | nil
  def default_expires_at(_category, :security, _from), do: nil

  def default_expires_at(category, class, %DateTime{} = from) do
    ms = category.default_expires_ms || Map.fetch!(@class_expires, class)
    DateTime.add(from, ms, :millisecond)
  end

  # PC-58 (7)
  # API-22
  @doc "Clamps a requested priority to the class ceiling; see `Relay.Policy.clamp_priority/2`."
  @spec clamp_priority(atom(), :low | :normal | :high | nil) ::
          {:low | :normal | :high, boolean()}
  def clamp_priority(class, requested), do: Relay.Policy.clamp_priority(class, requested)

  @doc "The notification fields of an evaluation from their stored names; see `Relay.Policy.Live.Inputs.notification/1`."
  @spec notification(map()) :: map()
  defdelegate notification(fields), to: Inputs

  # PC-58 (6)
  # INV-45
  @doc "Reads the frequency counters of a recipient on `channel` for a delivery of `class` in `category`, outside any transaction; nothing is counted."
  @spec frequency(Scope.t(), Inputs.category(), atom(), Relay.Id.t(), atom()) ::
          FrequencyCounter.readings() | :unavailable
  def frequency(%Scope{} = scope, category, class, recipient_id, channel) do
    keys = Relay.Policy.frequency_keys(class, channel, category.key, category.frequency, nil)
    read(scope, recipient_id, Relay.Id.generate(), keys)
  end

  # PC-58 (2)
  # PC-8
  # INV-15
  @doc """
  Evaluates the lattice for a delivery being opened, inside the accepting transaction. `input` carries `:scope`, `:now`, `:delivery_id`, `:recipient_id`, `:subtenant_id`, `:channel`, `:category`, `:workflow_key`, `:notification` (see `Relay.Policy.Live.Inputs.notification/1`) and `:frequency`. The kill switch stop point of acceptance runs after the delivery is opened (TN-40), so the snapshot carries none here; the delivery job evaluates every gate again.
  """
  @spec decide(map()) :: result()
  def decide(input) do
    input
    |> Map.merge(%{kill_switch: :allow, tenant_status: :active, scope_match: :match})
    |> Inputs.snapshot()
    |> Relay.Policy.evaluate()
  end

  # DS-24
  # DS-26
  # DS-27
  @doc "Records a lattice result on a delivery inside the caller's transaction; `send` changes nothing on a delivery opened to be sent."
  @spec record(Relay.Id.t(), result()) :: atom()
  def record(delivery_id, {:send, _info}) do
    result = Store.decide(delivery_id, "send", nil, nil, nil, nil)
    if result in [:recorded, :unchanged], do: emit(:send, nil)
    result
  end

  def record(delivery_id, {:skip, reason, rule_id, detail}),
    do: decide!(delivery_id, :skip, Atom.to_string(reason), rule_id, nil, detail)

  def record(delivery_id, {:defer, reason, rule_id, until, detail}),
    do: decide!(delivery_id, :defer, Atom.to_string(reason), rule_id, until, detail)

  def record(delivery_id, {:expire, rule_id, detail}),
    do: decide!(delivery_id, :expire, "expired", rule_id, nil, detail)

  # PC-46
  # PC-50
  # PC-58 (6)
  # WF-30
  @doc "The decision to record at acceptance for a lattice result, inside the accepting transaction; see `Relay.Policy.Live.Hold.hold/3`. `input` carries `:delivery_id`, `:notification_id`, `:recipient_id`, `:channel` and the `:category` of `category/4`. A held delivery's deferral is recorded with `record/2` and no job is queued for it."
  @spec hold(Scope.t(), Hold.input(), result()) :: {:held, result()} | :none
  def hold(%Scope{} = scope, input, result), do: Hold.hold(scope, input, result)

  # PC-46
  # PC-50
  # WF-30
  @doc "The release of the digest windows of the lattice (`config :relay, Relay.Workflow.Digest, release: Relay.Policy.Live`), inside the window's closing transaction; see `Relay.Policy.Live.Hold.release/2`."
  @spec digest_ready(Scope.t(), {atom(), map()}) :: :ok
  def digest_ready(%Scope{} = scope, outcome), do: Hold.release(scope, outcome)

  # DS-24
  # MD-12
  # TP-51
  @doc "Records a skip decided before the lattice (subscriber suspension, send mode `off`, sub-tenant scope, the subtype's channel rule, a template that cannot send) on an opened delivery with its detail, inside the caller's transaction."
  @spec record_skip(Relay.Id.t(), String.t(), String.t(), map()) :: atom()
  def record_skip(delivery_id, reason, rule_id, detail \\ %{}),
    do: decide!(delivery_id, :skip, reason, rule_id, nil, detail)

  # PC-58 (8)
  # DS-26
  @doc "The dry run answer of one channel for a lattice result: `send`, `skip` (an expiry is a skip with reason `expired`) or `defer`; `:error` when an input could not be read."
  @spec dry_run(String.t(), result()) :: {:ok, map()} | :error
  def dry_run(channel, {:send, _info}), do: {:ok, answer(channel, "send", nil, nil, nil)}

  def dry_run(channel, {:skip, reason, rule_id, _detail}),
    do: {:ok, answer(channel, "skip", Atom.to_string(reason), rule_id, nil)}

  def dry_run(channel, {:defer, reason, rule_id, until, _detail}),
    do: {:ok, answer(channel, "defer", Atom.to_string(reason), rule_id, until)}

  def dry_run(channel, {:expire, rule_id, _detail}),
    do: {:ok, answer(channel, "skip", "expired", rule_id, nil)}

  def dry_run(_channel, _unavailable), do: :error

  @doc "The dry run answer of a skip decided before the lattice."
  @spec dry_run_skip(String.t(), String.t(), String.t()) :: map()
  def dry_run_skip(channel, reason, rule_id), do: answer(channel, "skip", reason, rule_id, nil)

  defp answer(channel, decision, reason, rule_id, until) do
    %{
      "channel" => channel,
      "decision" => decision,
      "reason" => reason,
      "rule_id" => rule_id,
      "deferred_until" => whole_second(until)
    }
  end

  defp whole_second(nil), do: nil
  defp whole_second(%DateTime{} = at), do: %{at | microsecond: {0, 0}}

  # PC-8
  # PC-58 (2)
  # PC-58 (6)
  # INV-43
  # INV-45
  # TN-40
  @doc """
  The lattice step of a delivery job, run on every run. `{:send, info}`: the delivery may go and its frequency counters were counted; `{:defer, until}`: the deferral is recorded and the job runs again at `until`; `:held`: the delivery waits in a digest window that queues its job again when it fires (PC-46, PC-50, WF-30); `:done`: a skip, expiry or kill switch pause is recorded, or the delivery is gone or already closed; `{:error, {:input_unavailable, input}}`: nothing is recorded and the job retries.
  """
  @spec job(Scope.t(), Relay.Id.t()) :: job_result()
  def job(%Scope{} = scope, delivery_id) do
    case load(scope, delivery_id) do
      {:ok, nil} ->
        :done

      {:ok, {snapshot, hold}} ->
        run(scope, delivery_id, {snapshot, hold}, Relay.Policy.evaluate(snapshot))

      {:error, %Relay.Error{code: :not_found}} ->
        :done

      {:error, _reason} ->
        {:error, {:input_unavailable, :delivery}}
    end
  end

  # TN-40
  # TN-70 (2)
  # PC-58 (2)
  @impl Relay.Policy.Lattice
  @doc "Re-evaluates a paused delivery for a resume; nothing is recorded or counted here."
  @spec reevaluate(Relay.Policy.Lattice.delivery()) :: Relay.Policy.Lattice.decision()
  def reevaluate(%{scope: %Scope{} = scope, delivery_id: delivery_id}) do
    case load(scope, delivery_id) do
      {:ok, nil} -> {:error, :not_ready}
      {:ok, {snapshot, _hold}} -> port(Relay.Policy.evaluate(snapshot))
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  defp port({:send, _info}), do: {:send, "lattice:send"}
  defp port({:skip, reason, rule_id, _detail}), do: {:skip, Atom.to_string(reason), rule_id}

  defp port({:defer, reason, rule_id, until, _detail}),
    do: {:defer, Atom.to_string(reason), rule_id, until}

  defp port({:expire, rule_id, _detail}), do: {:expire, rule_id}
  defp port({:pause, rule_id, _detail}), do: {:pause, rule_id}
  defp port({:error, _reason}), do: {:error, :not_ready}

  defp load(scope, delivery_id) do
    kill_switches = KillSwitch.current_snapshot()
    now = Relay.Clock.business_now(scope)

    result =
      Store.in_scope(scope, fn status ->
        case Store.context(delivery_id) do
          nil -> nil
          context -> snapshot(scope, status, context, kill_switches, now)
        end
      end)

    case result do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, {snapshot, recipient_id, hold}} ->
        {:ok, {with_frequency(scope, recipient_id, snapshot), hold}}

      error ->
        error
    end
  end

  defp snapshot(scope, status, context, kill_switches, now) do
    class = Inputs.class(context["message_class"])
    key = context["category_key"]
    row = if key, do: Store.category(key, context["subtenant_id"])
    category = Inputs.category(row, key || context["message_class"], class)

    snapshot =
      Inputs.snapshot(%{
        scope: scope,
        now: now,
        delivery_id: context["id"],
        recipient_id: context["recipient_id"],
        subtenant_id: context["subtenant_id"],
        channel: Inputs.channel(context["channel"]),
        category: category,
        workflow_key: context["workflow_key"],
        notification:
          Inputs.notification(%{
            message_class: context["message_class"],
            security_subtype: context["security_subtype"],
            priority: context["priority"],
            expires_at: context["expires_at"],
            on_expire: context["on_expire"],
            timing_precision: context["timing_precision"],
            sender_type: context["sender_type"]
          }),
        scope_match: :match,
        kill_switch: kill_switch(scope, context, kill_switches),
        tenant_status: status,
        frequency: :unavailable
      })

    hold = %{
      delivery_id: context["id"],
      notification_id: context["notification_id"],
      recipient_id: context["recipient_id"],
      channel: snapshot.channel,
      category: category
    }

    {snapshot, context["recipient_id"], hold}
  end

  # TN-37
  # TN-38
  defp kill_switch(scope, context, kill_switches) do
    message = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      channel: context["channel"],
      message_class: context["message_class"],
      notification_id: context["notification_id"],
      subtenant_id: context["subtenant_id"],
      provider_account_id: context["provider_account_id"],
      workflow_id: context["workflow_id"],
      api_client_id: context["api_client_id"]
    }

    KillSwitch.evaluate(kill_switches, message, Relay.Clock.utc_now())
  end

  # PC-58 (6)
  # INV-45
  defp with_frequency(scope, recipient_id, snapshot) do
    keys = Relay.Policy.frequency_counters(snapshot)
    %{snapshot | frequency: read(scope, recipient_id, snapshot.delivery_id, keys)}
  end

  defp read(_scope, _recipient_id, _delivery_id, []), do: %{global: nil, policy: nil}

  defp read(scope, recipient_id, delivery_id, keys),
    do: FrequencyCounter.read(scope, recipient_id, delivery_id, keys, counter_options())

  defp run(scope, delivery_id, {snapshot, hold}, {:send, info} = result) do
    case in_scope!(scope, fn -> held_or(scope, delivery_id, hold, result) end) do
      {:held, recorded} when recorded in [:recorded, :unchanged] ->
        :held

      recorded when recorded in [:recorded, :unchanged] ->
        count(scope, snapshot, info)
        {:send, info}

      _closed_or_paused ->
        :done
    end
  end

  defp run(scope, delivery_id, _snapshot, {:pause, rule_id, %{kill_switch_id: id}}) do
    if in_scope!(scope, fn -> Store.pause(delivery_id, rule_id, id) end) == :paused,
      do: emit(:pause, :kill_switch)

    :done
  end

  defp run(_scope, _delivery_id, _snapshot, {:error, _reason} = error), do: error

  defp run(scope, delivery_id, {_snapshot, hold}, {:defer, _, _, until, _} = result) do
    case in_scope!(scope, fn -> held_or(scope, delivery_id, hold, result) end) do
      {:held, recorded} when recorded in [:recorded, :unchanged] -> :held
      recorded when recorded in [:recorded, :unchanged] -> {:defer, until}
      _closed_or_paused -> :done
    end
  end

  defp run(scope, delivery_id, _snapshot, result) do
    _ = in_scope!(scope, fn -> record(delivery_id, result) end)
    :done
  end

  # PC-46
  # PC-50
  # WF-30
  defp held_or(scope, delivery_id, hold, result) do
    case Hold.hold(scope, hold, result) do
      {:held, deferral} -> {:held, record(delivery_id, deferral)}
      :none -> record(delivery_id, result)
    end
  end

  # PC-50
  # PC-58 (6)
  defp count(_scope, _snapshot, %{counters: []}), do: :ok

  defp count(scope, snapshot, %{counters: counters}) do
    %{recipient_id: recipient_id, delivery_id: delivery_id} = snapshot
    _ = FrequencyCounter.record(scope, recipient_id, delivery_id, counters, counter_options())
    :ok
  end

  defp counter_options do
    :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:frequency_counter, [])
  end

  defp in_scope!(scope, fun) do
    {:ok, result} = Store.in_scope(scope, fn _status -> fun.() end)
    result
  end

  defp decide!(delivery_id, kind, reason, rule_id, until, detail) do
    result = Store.decide(delivery_id, Atom.to_string(kind), reason, rule_id, until, detail)
    if result == :recorded, do: emit(kind, reason)
    result
  end

  # DS-24
  defp emit(kind, reason) do
    tag = if reason, do: reason, else: :none
    :telemetry.execute([:relay, :policy, :decision], %{count: 1}, %{decision: kind, reason: tag})
  end
end
