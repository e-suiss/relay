defmodule Relay.Tenancy.KillSwitch do
  @moduledoc """
  The kill switch (TN-36…TN-45, TN-47, TN-70): one model with five dimensions (scope × channel × target × message class × state), stored in PostgreSQL, propagated by a Valkey reload signal and read from an immutable node cache.

  A blocked delivery is never an error: it becomes `PAUSED` with a `rule_id`, is not deleted, not retried and not sent when the record's TTL passes; only a resume through the policy lattice or a bulk cancel ends the pause, and a paused delivery whose message expires closes as `expired` (TN-40). There are three stop points: acceptance, a sweep job that pauses the pending deliveries a new record matches, and the first step of every delivery job (`first_step/3`, T-15 (5)).

  Every write is authorized by `Relay.Tenancy.KillSwitch.Authz` before it reaches the database, is audited and goes to the outbox in the same transaction, and signals the nodes after it commits. In stage 2 the only surface for writes is the release command `Relay.Release.KillSwitch` of the installation operator (TN-70 (1)).
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Platform.Leadership,
      Relay.Audit,
      Relay.Policy.Lattice,
      Relay.Tenancy.DeadMan
    ],
    exports: []

  require Logger

  alias Relay.Actor
  alias Relay.Policy.Lattice
  alias Relay.Scope
  alias Relay.Tenancy.DeadMan
  alias Relay.Tenancy.KillSwitch.Authz
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Evaluation
  alias Relay.Tenancy.KillSwitch.Record
  alias Relay.Tenancy.KillSwitch.Snapshot
  alias Relay.Tenancy.KillSwitch.Store
  alias Relay.Tenancy.KillSwitch.Sweep

  @batch 500
  @pausing [:off, :canary, :paused_until]

  @type operator :: Authz.actor()
  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Supervised children: the node's kill switch cache, unless `config :relay, Relay.Tenancy.KillSwitch.Cache, enabled: false`."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    if Keyword.get(Application.get_env(:relay, Cache, []), :enabled, true),
      do: [Supervisor.child_spec(Cache, [])],
      else: []
  end

  # TN-38
  # INV-43
  @doc "Returns true once the node has read the kill switch state at least once; until then it sends nothing."
  @spec ready?() :: boolean()
  def ready?, do: Cache.current() != :unknown

  @doc "Returns the node's current kill switch snapshot, `:unknown` before the first read."
  @spec snapshot() :: Snapshot.t() | :unknown
  def snapshot, do: Cache.current()

  # TN-37
  # TN-38
  # TN-42
  @doc "Evaluates the kill switches for one message; see `Relay.Tenancy.KillSwitch.Evaluation.evaluate/3`."
  @spec evaluate(Snapshot.t() | :unknown, Evaluation.message(), DateTime.t()) ::
          Evaluation.decision()
  defdelegate evaluate(snapshot, message, now), to: Evaluation

  # TN-37
  @doc "Evaluates one message against the node's current snapshot."
  @spec check(Evaluation.message()) :: Evaluation.decision()
  def check(message), do: evaluate(snapshot(), message, Relay.Clock.utc_now())

  # T-15 (5)
  # TN-40
  # TN-38
  @doc """
  The first step of a delivery job: reads the delivery's state and evaluates the kill switches. Returns `{:send, gate}` when the job may go on; `{:done, reason}` when the job ends without work and without error (`:cancelled`, `:paused`, `:expired`, `:terminal`, `:not_found`): a delivery a kill switch matches is marked `PAUSED` here and is not retried; `{:deferred, gate}` for a deferred delivery and `{:snooze, 5}` while the node has no kill switch state. `opts`: `:snapshot` (defaults to the node's).
  """
  @spec first_step(Scope.t(), Relay.Id.t(), keyword()) ::
          {:send, map()} | {:deferred, map()} | {:done, atom()} | {:snooze, 5}
  def first_step(%Scope{} = scope, delivery_id, opts \\ []) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &snapshot/0)
    now = Relay.Clock.utc_now()

    case Store.in_scope(scope, fn _status -> gate_step(scope, delivery_id, snapshot, now) end) do
      {:ok, outcome} -> outcome
      {:error, %Relay.Error{code: :not_found}} -> {:done, :not_found}
    end
  end

  # TN-40 (1)
  @doc """
  The acceptance stop point; call it inside the accepting transaction, right after the delivery is opened. A delivery a kill switch matches is marked `PAUSED` in the same transaction and the caller inserts no job for it (`{:paused, rule_id}`); `:allow` and `:hold` (no kill switch state yet: the job's first step holds it) mean the caller inserts the job. `opts`: `:snapshot` (defaults to the node's).
  """
  @spec at_acceptance(Relay.Id.t(), keyword()) :: :allow | :hold | {:paused, String.t()}
  def at_acceptance(delivery_id, opts \\ []) do
    scope = Store.current_scope!()
    snapshot = Keyword.get_lazy(opts, :snapshot, &snapshot/0)
    gate = Store.gate(delivery_id)

    case evaluate(snapshot, message(scope, gate), Relay.Clock.utc_now()) do
      :allow ->
        :allow

      {:hold, _rule_id} ->
        :hold

      {:pause, kill_switch_id, rule_id} ->
        _ = Store.pause(delivery_id, rule_id, kill_switch_id)
        {:paused, rule_id}
    end
  end

  defp gate_step(scope, delivery_id, snapshot, now) do
    gate = Store.gate(delivery_id)

    case gate["result"] do
      :sendable ->
        case evaluate(snapshot, message(scope, gate), now) do
          :allow ->
            {:send, gate}

          {:pause, kill_switch_id, rule_id} ->
            _ = Store.pause(delivery_id, rule_id, kill_switch_id)
            {:done, :paused}

          {:hold, _rule_id} ->
            {:snooze, 5}
        end

      :expired ->
        _ = Store.expire(delivery_id, "delivery.expired")
        {:done, :expired}

      :deferred ->
        {:deferred, gate}

      result ->
        {:done, result}
    end
  end

  defp message(scope, gate) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      channel: gate["channel"],
      message_class: gate["message_class"],
      notification_id: gate["notification_id"],
      subtenant_id: gate["subtenant_id"],
      provider_account_id: gate["provider_account_id"]
    }
  end

  # TN-36
  # TN-41
  # TN-42
  # TN-40
  # T-15 (2)
  @doc """
  Engages a kill switch. `spec` carries `:scope_kind`, `:scope` (the record's tenant scope; ignored for `:platform`, which lives in the installation scope), `:scope_ref`, `:channel`, `:target` (`:all`, `{:provider_account, ref}` or `{:template, ref}`), `:message_class`, `:security_approval`, `:state` (`:off`, `{:canary, 1..99}` or `{:paused_until, DateTime}`), `:reason`, `:ticket`, `:expires_at` and `:no_ttl_approval`. A record that pauses inserts its sweep job in the same transaction; the nodes are signalled after the commit.
  """
  @spec engage(map(), operator()) :: result()
  def engage(spec, %{kind: _, ref: _} = operator) do
    with :ok <- Authz.authorize(operator, :engage, authz_spec(spec)),
         {:ok, scope} <- record_scope(spec),
         {:ok, attrs} <- engage_attrs(spec, :operator) do
      write_engage(scope, attrs, actor(operator))
    end
  end

  defp write_engage(scope, attrs, actor) do
    digest = digest(scope, engaged_action(attrs.origin), actor, attrs.id, attrs.reason)

    result =
      Store.in_scope(scope, fn _status ->
        {code, id, generation} = Store.engage(attrs, digest, actor)
        if code == :engaged and attrs.state in @pausing, do: sweep_job(scope, id, attrs)
        {code, id, generation}
      end)

    case result do
      {:ok, {code, id, generation}} when code in [:engaged, :exists, :dead_man_active] ->
        if code == :engaged, do: announce(generation)
        {:ok, %{result: code, id: id && Record.external_id(id), generation: generation}}

      {:ok, {code, _id, _generation}} ->
        {:error, code}

      {:error, %Relay.Error{code: code}} ->
        {:error, code}
    end
  end

  defp engaged_action(:dead_man), do: "killswitch.auto_paused"
  defp engaged_action(:operator), do: "killswitch.engaged"

  defp sweep_job(scope, id, attrs) do
    Store.insert_job(
      Sweep.new(%{
        "kill_switch_id" => Relay.Id.to_string(id),
        "tenant_id" => Scope.tenant_text(scope),
        "environment" => Relay.Environment.dump(scope.environment),
        "platform" => attrs.scope_kind == :platform
      })
    )
  end

  # TN-22
  # TN-70 (1)
  @doc "Replaces an active kill switch by a record of the same dimensions with a new state and TTL; a replacement that relaxes needs `:relax_approval`."
  @spec replace(String.t() | Relay.Id.t(), map(), operator()) :: result()
  def replace(id, change, %{kind: _, ref: _} = operator) do
    with {:ok, old} <- active_record(id),
         {:ok, state} <- state_attrs(Map.get(change, :state, :off)),
         new = Map.merge(state, %{expires_at: Map.get(change, :expires_at)}),
         spec =
           Map.merge(change, %{scope_kind: old.scope_kind, relaxes?: Authz.relaxes?(old, new)}),
         :ok <- Authz.authorize(operator, :replace, spec),
         do: write_replace(old, new, change, actor(operator))
  end

  defp write_replace(old, new, change, actor) do
    scope = Scope.new!(old.tenant_id, old.environment)
    new_id = Relay.Id.generate()
    digest = digest(scope, "killswitch.engaged", actor, new_id, change.reason)

    attrs =
      Map.merge(new, %{
        id: new_id,
        reason: change.reason,
        no_ttl_approval_ref: Map.get(change, :no_ttl_approval),
        release_approval_ref: Map.get(change, :relax_approval)
      })

    result =
      Store.in_scope(scope, fn _status ->
        {code, kill_switch_id, generation} = Store.replace(old.id, attrs, digest, actor)

        if code == :replaced and attrs.state in @pausing,
          do: sweep_job(scope, kill_switch_id, old)

        {code, kill_switch_id, generation}
      end)

    case result do
      {:ok, {:replaced, kill_switch_id, generation}} ->
        announce(generation)

        {:ok,
         %{
           result: :replaced,
           id: Record.external_id(kill_switch_id),
           replaced: Record.external_id(old.id),
           generation: generation
         }}

      {:ok, {code, _id, _generation}} ->
        {:error, code}

      {:error, %Relay.Error{code: code}} ->
        {:error, code}
    end
  end

  # TN-22
  # TN-40
  # TN-70 (1)
  @doc "Releases an active kill switch; releasing relaxes and needs `:relax_approval`. Paused deliveries stay paused (TN-40)."
  @spec release(String.t() | Relay.Id.t(), map(), operator()) :: result()
  def release(id, change, %{kind: _, ref: _} = operator) do
    with {:ok, record} <- active_record(id),
         :ok <-
           Authz.authorize(operator, :release, Map.put(change, :scope_kind, record.scope_kind)) do
      scope = Scope.new!(record.tenant_id, record.environment)
      actor = actor(operator)
      digest = digest(scope, "killswitch.released", actor, record.id, change.reason)

      result =
        Store.in_scope(scope, fn _status ->
          Store.release(record.id, change.reason, Map.get(change, :relax_approval), digest, actor)
        end)

      case result do
        {:ok, {:released, generation}} ->
          announce(generation)
          {:ok, %{result: :released, id: Record.external_id(record.id), generation: generation}}

        {:ok, {code, _generation}} ->
          {:error, code}

        {:error, %Relay.Error{code: code}} ->
          {:error, code}
      end
    end
  end

  # TN-40
  # TN-70 (2)
  @doc """
  Resumes the deliveries a kill switch paused: each one passes the policy lattice again (`Relay.Policy.Lattice`); `send` lifts the pause and, in the same transaction, inserts the job `:job` builds for it, `skip` cancels it with the lattice's rule. A lattice that is not ready stops the command at the first delivery with `:policy_lattice_unavailable` and nothing changes. `change` carries `:reason`, `:relax_approval` and the optional `:lattice` and `:job` (a function of the scope and the delivery identifier returning an Oban job changeset).
  """
  @spec resume(String.t() | Relay.Id.t(), map(), operator()) :: result()
  def resume(id, change, %{kind: _, ref: _} = operator) do
    with {:ok, kill_switch_id} <- decode_id(id),
         :ok <- Authz.authorize(operator, :resume, Map.put_new(change, :scope_kind, :platform)) do
      run = %{
        id: kill_switch_id,
        lattice: Map.get(change, :lattice, Lattice.impl()),
        job: Map.get(change, :job),
        actor: actor(operator)
      }

      kill_switch_id
      |> Store.scopes()
      |> Enum.reduce_while({:ok, %{resumed: 0, cancelled: 0}}, &resume_scope(&1, run, &2))
    end
  end

  defp resume_scope(scope, run, {:ok, totals}) do
    {:ok, ids} = Store.in_scope(scope, fn _status -> Store.paused(run.id, @batch) end)

    case Enum.reduce_while(ids, {:ok, totals}, &resume_delivery(scope, &1, run, &2)) do
      {:ok, totals} when length(ids) == @batch -> resume_scope(scope, run, {:ok, totals})
      {:ok, totals} -> {:cont, {:ok, totals}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp resume_delivery(scope, delivery_id, run, {:ok, acc}) do
    case Lattice.reevaluate(%{scope: scope, delivery_id: delivery_id}, run.lattice) do
      {:error, :not_ready} ->
        {:halt, {:error, :policy_lattice_unavailable}}

      {:send, decision_ref} ->
        {:cont, {:ok, resume_one(scope, delivery_id, decision_ref, run.job, acc)}}

      {:skip, _reason, rule_id} ->
        {:cont, {:ok, cancel_one(scope, delivery_id, rule_id, run.actor, acc)}}
    end
  end

  defp resume_one(scope, delivery_id, decision_ref, job, acc) do
    {:ok, result} =
      Store.in_scope(scope, fn _status ->
        result = Store.resume(delivery_id, decision_ref, "killswitch.resume")
        if result == :resumed and job, do: Store.insert_job(job.(scope, delivery_id))
        result
      end)

    if result == :resumed, do: Map.update!(acc, :resumed, &(&1 + 1)), else: acc
  end

  defp cancel_one(scope, delivery_id, rule_id, actor, acc) do
    digest =
      Relay.Audit.record_digest(%{
        tenant_id: scope.tenant_id,
        environment: Relay.Environment.dump(scope.environment),
        action: "delivery.cancelled",
        actor_kind: Atom.to_string(actor.kind),
        actor_ref: actor.ref,
        on_behalf_of_ref: actor.on_behalf_of_ref,
        target_type: "delivery",
        target_id: Relay.Id.to_string(delivery_id),
        reason: rule_id
      })

    {:ok, result} =
      Store.in_scope(scope, fn _status -> Store.cancel(delivery_id, rule_id, digest, actor) end)

    if result == :cancelled, do: Map.update!(acc, :cancelled, &(&1 + 1)), else: acc
  end

  # TN-47
  @doc "Cancels every delivery a kill switch paused, batch by batch, each with `delivery.cancelled` and the rule `killswitch.bulk_cancel:<ksw_…>`; the command writes one `killswitch.bulk_cancelled` audit record before its first batch."
  @spec bulk_cancel(String.t() | Relay.Id.t(), map(), operator()) :: result()
  def bulk_cancel(id, change, %{kind: _, ref: _} = operator) do
    with {:ok, kill_switch_id} <- decode_id(id),
         :ok <-
           Authz.authorize(operator, :bulk_cancel, Map.put_new(change, :scope_kind, :platform)) do
      actor = actor(operator)
      scope = installation_scope()
      external = Record.external_id(kill_switch_id)
      rule_id = "killswitch.bulk_cancel:" <> external
      audit_id = Relay.Id.generate()

      digest =
        Relay.Audit.record_digest(%{
          tenant_id: scope.tenant_id,
          environment: "live",
          action: "killswitch.bulk_cancelled",
          actor_kind: Atom.to_string(actor.kind),
          actor_ref: actor.ref,
          on_behalf_of_ref: actor.on_behalf_of_ref,
          target_type: "kill_switch",
          target_id: Relay.Id.to_string(kill_switch_id),
          reason: change.reason
        })

      {:ok, :appended} =
        Store.in_scope(scope, fn _status ->
          Store.audit(
            audit_id,
            "killswitch.bulk_cancelled",
            "kill_switch",
            Relay.Id.to_string(kill_switch_id),
            change.reason,
            digest,
            actor
          )
        end)

      totals =
        kill_switch_id
        |> Store.scopes()
        |> Enum.reduce(
          %{cancelled: 0, batches: 0},
          &cancel_scope(&1, kill_switch_id, rule_id, &2)
        )

      {:ok, Map.merge(totals, %{id: external, rule_id: rule_id})}
    end
  end

  defp cancel_scope(scope, kill_switch_id, rule_id, totals) do
    {:ok, {cancelled, more?}} =
      Store.in_scope(scope, fn _status -> Store.cancel_paused(kill_switch_id, rule_id, @batch) end)

    totals = %{cancelled: totals.cancelled + cancelled, batches: totals.batches + 1}
    if more?, do: cancel_scope(scope, kill_switch_id, rule_id, totals), else: totals
  end

  # TN-41
  @doc "Lists the kill switches of `scope`, including the platform records that apply to it. `opts`: `:include_released`, `:after` and `:limit`."
  @spec list(Scope.t(), keyword()) :: {:ok, [Record.t()]} | {:error, Relay.Error.t()}
  def list(%Scope{} = scope, opts \\ []) do
    Store.in_scope(scope, fn _status ->
      Store.list(
        Keyword.get(opts, :include_released, false),
        Keyword.get(opts, :after),
        Keyword.get(opts, :limit, 100)
      )
    end)
  end

  @doc "Lists every kill switch record in force, across tenants."
  @spec list_active() :: {:ok, [Record.t()]} | {:error, Relay.Error.t()}
  def list_active do
    with {:ok, _generation, records} <- Store.snapshot(), do: {:ok, records}
  end

  @doc "Reads one kill switch record in force by its identifier."
  @spec show(String.t() | Relay.Id.t()) :: {:ok, Record.t()} | {:error, atom()}
  def show(id), do: active_record(id)

  @doc "Describes a record for an operator: external identifiers, dimensions, state, reason, origin, creator, expiry and status."
  @spec describe(Record.t()) :: map()
  def describe(%Record{} = record) do
    %{
      id: Record.external_id(record.id),
      tenant: Relay.ExternalId.encode("ten", record.tenant_id),
      environment: record.environment,
      scope: record.scope_kind,
      scope_ref: record.scope_ref,
      channel: record.channel,
      target:
        if(record.target_kind == :all, do: :all, else: {record.target_kind, record.target_ref}),
      message_class: record.message_class,
      state: state_view(record),
      reason: record.reason,
      ticket: record.ticket_ref,
      origin: record.origin,
      created_by: record.created_by_ref,
      expires_at: record.expires_at,
      status: record.status,
      created_at: record.created_at
    }
  end

  defp state_view(%Record{state: :canary, canary_percent: percent}), do: {:canary, percent}

  defp state_view(%Record{state: :paused_until, paused_until: until}),
    do: {:paused_until, until || :infinity}

  defp state_view(%Record{state: state}), do: state

  # TN-44
  @doc "Pauses the pending deliveries of `scope` that a kill switch matches, batch by batch, for at most `max_batches` batches; returns the number paused and whether work is left."
  @spec sweep(Scope.t(), Relay.Id.t(), pos_integer()) :: {non_neg_integer(), boolean()}
  def sweep(%Scope{} = scope, kill_switch_id, max_batches \\ 20) do
    Enum.reduce_while(1..max_batches, {0, false}, fn _n, {total, _more} ->
      {:ok, {paused, more?}} =
        Store.in_scope(scope, fn _status -> Store.pause_matching(kill_switch_id, @batch) end)

      if more?, do: {:cont, {total + paused, true}}, else: {:halt, {total + paused, false}}
    end)
  end

  @doc "Lists the scopes the sweep of a kill switch visits: its own, or for a platform record every scope with pending or paused deliveries."
  @spec sweep_scopes(Scope.t(), Relay.Id.t(), boolean()) :: [Scope.t()]
  def sweep_scopes(scope, _kill_switch_id, false), do: [scope]
  def sweep_scopes(_scope, kill_switch_id, true), do: Store.scopes(kill_switch_id)

  # TN-40
  @doc "Closes the paused deliveries whose message expired in every scope that holds paused deliveries; returns how many closed."
  @spec expire_paused() :: non_neg_integer()
  def expire_paused do
    for scope <- Store.scopes(nil), reduce: 0 do
      total -> total + expire_scope(scope)
    end
  end

  defp expire_scope(scope) do
    {:ok, expired} = Store.in_scope(scope, fn _status -> Store.expire_paused(@batch) end)
    if expired == @batch, do: expired + expire_scope(scope), else: expired
  end

  # TN-43
  # T-91 (1)
  @doc """
  Counts one attempt start for the dead-man switch and pauses each scope whose rate trips it (`Relay.Tenancy.DeadMan`). `message` carries `:message_class` and the optional `:campaign_id` and `:workflow_id`; a `security` message is not counted. `opts`: `:counter` (a function of the scope, the key and the windows returning `{current_sum, baseline_sum}`). Returns the kill switch results of the scopes that tripped.
  """
  @spec record_attempt(Scope.t(), map(), keyword()) :: [map()]
  def record_attempt(%Scope{} = scope, message, opts \\ []) do
    if to_string(message.message_class) == "security" do
      []
    else
      counter = Keyword.get(opts, :counter, &pg_counter/3)
      params = DeadMan.params()

      for {kind, ref} <- dead_man_scopes(message),
          sums = counter.(scope, DeadMan.key(kind, ref), params),
          DeadMan.trip?(sums, params),
          {:ok, result} <- [dead_man_engage(scope, kind, ref, sums, params)] do
        result
      end
    end
  end

  defp dead_man_scopes(message) do
    [{:tenant, nil}] ++
      for {kind, field} <- [campaign: :campaign_id, workflow: :workflow_id],
          ref = scope_ref(Map.get(message, field)),
          is_binary(ref),
          do: {kind, ref}
  end

  defp pg_counter(scope, key, params) do
    {:ok, sums} =
      Store.in_scope(scope, fn _status ->
        Store.ring(key, 1, params.current_minutes, params.baseline_minutes)
      end)

    sums
  end

  defp dead_man_engage(scope, kind, ref, sums, params) do
    attrs = %{
      id: Relay.Id.generate(),
      scope_kind: kind,
      scope_ref: ref,
      channel: nil,
      target_kind: :all,
      target_ref: nil,
      message_class: nil,
      security_approval_ref: nil,
      state: :paused_until,
      canary_percent: nil,
      paused_until: :infinity,
      reason: DeadMan.reason(sums, params),
      ticket_ref: nil,
      expires_at: nil,
      no_ttl_approval_ref: "TN-43",
      origin: :dead_man
    }

    actor = %Actor{kind: :system, ref: "system:dead_man", on_behalf_of_ref: "system:dead_man"}

    :telemetry.execute([:relay, :kill_switch, :dead_man, :tripped], %{current: elem(sums, 0)}, %{
      scope_kind: kind
    })

    Logger.error("dead-man switch tripped; the scope is paused until an operator releases it",
      scope_kind: kind
    )

    write_engage(scope, attrs, actor)
  end

  defp announce(generation) do
    topic = Cache.topic()

    with {:error, error} <- Relay.Platform.publish_signal(topic, generation),
         do: Logger.warning("kill switch signal not sent; nodes poll", code: error.code)

    _ = Relay.Platform.wake_outbox()

    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> send(pid, {:relay_signal, topic, {:seq, generation}})
    end

    :ok
  end

  defp active_record(id) do
    with {:ok, kill_switch_id} <- decode_id(id),
         {:ok, _generation, records} <- read_snapshot() do
      case Enum.find(records, &(&1.id == kill_switch_id)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  defp read_snapshot do
    case Store.snapshot() do
      {:ok, generation, records} -> {:ok, generation, records}
      {:error, %Relay.Error{code: code}} -> {:error, code}
    end
  end

  defp decode_id(<<_::128>> = id), do: {:ok, id}

  defp decode_id(text) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["ksw"]) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :invalid_id}
    end
  end

  defp decode_id(_other), do: {:error, :invalid_id}

  defp record_scope(%{scope_kind: :platform}), do: {:ok, installation_scope()}
  defp record_scope(%{scope: %Scope{} = scope}), do: {:ok, scope}
  defp record_scope(_spec), do: {:error, :tenant_required}

  defp installation_scope, do: Scope.new!(Store.installation_tenant_id(), :live)

  defp engage_attrs(spec, origin) do
    with {:ok, state} <- state_attrs(Map.get(spec, :state, :off)),
         {:ok, target_kind, target_ref} <- target(Map.get(spec, :target, :all)) do
      {:ok,
       Map.merge(state, %{
         id: Relay.Id.generate(),
         scope_kind: spec.scope_kind,
         scope_ref: scope_ref(Map.get(spec, :scope_ref)),
         channel: text(Map.get(spec, :channel)),
         target_kind: target_kind,
         target_ref: target_ref,
         message_class: text(Map.get(spec, :message_class)),
         security_approval_ref: Map.get(spec, :security_approval),
         reason: spec.reason,
         ticket_ref: Map.get(spec, :ticket),
         expires_at: Map.get(spec, :expires_at),
         no_ttl_approval_ref:
           if(Map.get(spec, :expires_at), do: nil, else: Map.get(spec, :no_ttl_approval)),
         origin: origin
       })}
    end
  end

  defp state_attrs(:off), do: {:ok, %{state: :off, canary_percent: nil, paused_until: nil}}
  defp state_attrs(:on), do: {:ok, %{state: :on, canary_percent: nil, paused_until: nil}}

  defp state_attrs({:canary, percent}) when is_integer(percent) and percent in 1..99,
    do: {:ok, %{state: :canary, canary_percent: percent, paused_until: nil}}

  defp state_attrs({:paused_until, %DateTime{} = until}),
    do: {:ok, %{state: :paused_until, canary_percent: nil, paused_until: until}}

  defp state_attrs(_state), do: {:error, :invalid_state}

  defp target(:all), do: {:ok, :all, nil}

  defp target({kind, ref}) when kind in [:provider_account, :template] do
    case scope_ref(ref) do
      ref when is_binary(ref) -> {:ok, kind, ref}
      _ -> {:error, :invalid_target}
    end
  end

  defp target(_target), do: {:error, :invalid_target}

  defp scope_ref(nil), do: nil
  defp scope_ref(<<_::128>> = id), do: Relay.Id.to_string(id)

  defp scope_ref(text) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["stn", "wfl", "tpl"]) do
      {:ok, id} -> Relay.Id.to_string(id)
      {:error, _} -> text
    end
  end

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value

  defp authz_spec(spec) do
    %{
      scope_kind: spec[:scope_kind],
      reason: spec[:reason],
      message_class: spec[:message_class],
      security_approval: spec[:security_approval],
      expires_at: spec[:expires_at],
      no_ttl_approval: spec[:no_ttl_approval]
    }
  end

  defp actor(%{kind: :installation_operator, ref: ref}),
    do: %Actor{kind: :installation_operator, ref: ref, on_behalf_of_ref: ref}

  defp digest(scope, action, actor, id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: "kill_switch",
      target_id: Relay.Id.to_string(id),
      reason: reason
    })
  end
end
