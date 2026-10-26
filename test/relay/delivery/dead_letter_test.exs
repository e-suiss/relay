defmodule Relay.Delivery.DeadLetterTest do
  use Relay.DataCase, async: false

  @moduletag :capture_log

  alias Relay.Delivery
  alias Relay.Delivery.DeadLetters
  alias Relay.Delivery.DeadLetters.AutoReplay
  alias Relay.Repo
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture
  alias RelayTest.TenantFixture.SendWorker

  setup do
    TenantFixture.as_role("relay_worker")
    previous = Application.get_env(:relay, Relay.Delivery)

    Application.put_env(
      :relay,
      Relay.Delivery,
      Keyword.put(previous || [], :send_worker, SendWorker)
    )

    on_exit(fn -> Application.put_env(:relay, Relay.Delivery, previous) end)
    %{parameters: DeliveryFixture.parameters(1)}
  end

  defp failed!(ctx, opts \\ []) do
    fixture =
      DeliveryFixture.sendable!(
        notification: Keyword.get(opts, :notification, []),
        delivery: Keyword.get(opts, :delivery, provider: "apns")
      )

    key = Keyword.get(opts, :key, "pik-" <> TenantFixture.random())
    attempt = DeliveryFixture.started_attempt!(fixture.scope, fixture.delivery_id, key)

    failure =
      DeliveryFixture.failure(
        fixture.delivery_id,
        attempt,
        ctx.parameters,
        Keyword.get(opts, :failure, failure_class: "quota", condition: nil)
      )

    {:ok, {:applied, {:dead_letter, class, rule}, {:recorded, id}}} =
      Delivery.fail_attempt(fixture.scope, failure)

    Map.merge(fixture, %{dead_letter_id: id, class: class, rule: rule, key: key, attempt: attempt})
  end

  defp job(%{attempt_no: n, dead_letter_id: id, delivery_id: delivery_id}) do
    SendWorker.new(
      %{
        "delivery_id" => Relay.Id.to_string(delivery_id),
        "attempt_no" => n,
        "dead_letter_id" => Relay.Id.to_string(id)
      },
      queue: :dlq_replay
    )
  end

  defp letter(scope, id) do
    {:ok, letters} = Delivery.list_dead_letters(scope, limit: 1000)
    Enum.find(letters, &(&1["id"] == id))
  end

  defp attempt_key(scope, delivery_id, n) do
    {:ok, [[key]]} =
      Repo.in_scope(scope, fn _ ->
        Repo.scoped_query!(
          "SELECT tenant_id, environment, provider_idempotency_key FROM relay.delivery_attempts WHERE delivery_id = $1 AND attempt_no = $2",
          [delivery_id, n]
        ).rows
        |> Enum.map(&[List.last(&1)])
      end)

    key
  end

  defp jobs(queue, delivery_id) do
    Repo.query!(
      "SELECT args FROM relay_queue.oban_jobs WHERE queue = $1 AND args->>'delivery_id' = $2",
      [queue, Relay.Id.to_string(delivery_id)]
    ).rows
  end

  describe "T-29 classified table" do
    test "T-29: a dead letter records the class, provider, code, attempts, times and blind index",
         ctx do
      f = failed!(ctx)
      assert {f.class, f.rule} == {:exhausted, "channel_parameters.missing"}

      assert %{
               "dlq_class" => "exhausted",
               "failure_class" => "quota",
               "channel" => "email",
               "provider" => "apns",
               "message_class" => "transactional",
               "raw_code" => "429",
               "attempt_count" => 1,
               "invalidates_target" => false,
               "replay_depth" => 0,
               "state" => "open",
               "target_key" => <<_::256>>
             } = l = letter(f.scope, f.dead_letter_id)

      assert DateTime.compare(l["first_attempt_at"], l["last_attempt_at"]) in [:lt, :eq]

      assert {:ok,
              %{"failure_kind" => "failed", "failure_rule_id" => "channel_parameters.missing"}} =
               Delivery.delivery(f.scope, f.delivery_id)
    end

    test "T-29: the four classes come from the plan and from an explicit record", ctx do
      permanent = failed!(ctx, failure: [failure_class: "permanent_content", condition: nil])
      assert permanent.class == :permanent

      single =
        Map.update!(ctx.parameters, :backoff, fn rows ->
          Enum.map(rows, &if(&1["channel"] == "email", do: %{&1 | "max_attempts" => 1}, else: &1))
        end)

      exhausted =
        failed!(ctx,
          failure: [failure_class: "transient", condition: "rate_limited", parameters: single]
        )

      assert {exhausted.class, exhausted.rule} == {:exhausted, "retry.max_attempts"}

      budget =
        failed!(ctx,
          failure: [failure_class: "transient", condition: "rate_limited", budget: :deny]
        )

      assert {budget.class, budget.rule} == {:budget_denied, "retry.budget_denied"}

      f = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(f.scope, f.delivery_id)
      DeliveryFixture.finish(f.scope, f.delivery_id, n, :failed, failure_class: "transient")

      assert {:ok, {:recorded, id}} =
               Delivery.record_dead_letter(f.scope, %{
                 delivery_id: f.delivery_id,
                 dlq_class: :quality_alarm,
                 failure_class: "transient",
                 entry_rule_id: "quality.complaint_rate"
               })

      assert %{"dlq_class" => "quality_alarm"} = letter(f.scope, id)
    end

    test "T-29: a delivery has at most one open dead letter", ctx do
      f = failed!(ctx)

      assert {:ok, {:already_open, id}} =
               Delivery.record_dead_letter(f.scope, %{
                 delivery_id: f.delivery_id,
                 dlq_class: :exhausted,
                 failure_class: "quota",
                 entry_rule_id: "retry.max_attempts"
               })

      assert id == f.dead_letter_id
    end

    test "T-29: the replay checks of the table are in place" do
      names =
        Repo.query!(
          "SELECT conname::text FROM pg_constraint WHERE conrelid = 'relay.dead_letters'::regclass AND contype = 'c'"
        ).rows
        |> List.flatten()

      for name <- ~w(dead_letters_invalidates_target_check dead_letters_never_replayed_check
                     dead_letters_replay_depth_limit_check dead_letters_approval_check
                     dead_letters_cause_fixed_check dead_letters_replay_of_id_check),
          do: assert(name in names, name)
    end
  end

  describe "T-29 replay rules" do
    test "T-29 (1): a dead letter that invalidated its target is never replayed", ctx do
      f = failed!(ctx, failure: [failure_class: "permanent_target", condition: nil])
      assert %{"invalidates_target" => true} = letter(f.scope, f.dead_letter_id)

      assert {:ok, {:not_replayable, nil}} =
               Delivery.replay_dead_letter(f.scope, f.dead_letter_id,
                 job: &job/1,
                 cause_fixed_ref: "ticket-1"
               )

      assert %{"state" => "closed", "close_reason" => "not_replayable"} =
               letter(f.scope, f.dead_letter_id)
    end

    test "T-29 (1): quality_alarm needs a human approval and permanent a fixed cause", ctx do
      permanent = failed!(ctx, failure: [failure_class: "sender_config", condition: nil])

      assert {:ok, {:cause_fix_required, nil}} =
               Delivery.replay_dead_letter(permanent.scope, permanent.dead_letter_id, job: &job/1)

      assert {:ok, {:replay_opened, 2}} =
               Delivery.replay_dead_letter(permanent.scope, permanent.dead_letter_id,
                 job: &job/1,
                 cause_fixed_ref: "sender-fixed-1"
               )

      f = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(f.scope, f.delivery_id)
      DeliveryFixture.finish(f.scope, f.delivery_id, n, :failed, failure_class: "transient")

      {:ok, {:recorded, id}} =
        Delivery.record_dead_letter(f.scope, %{
          delivery_id: f.delivery_id,
          dlq_class: :quality_alarm,
          failure_class: "transient",
          entry_rule_id: "quality.alarm"
        })

      assert {:ok, {:approval_required, nil}} =
               Delivery.replay_dead_letter(f.scope, id, job: &job/1)

      assert {:ok, {:replay_opened, 2}} =
               Delivery.replay_dead_letter(f.scope, id, job: &job/1, approval_ref: "approval-7")
    end

    test "T-29 (2): a dead letter past the message's useful life closes as expired", ctx do
      f = failed!(ctx, notification: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:ok, {:expired, nil}} =
               Delivery.replay_dead_letter(f.scope, f.dead_letter_id, job: &job/1)

      assert %{"state" => "closed", "close_reason" => "expired"} =
               letter(f.scope, f.dead_letter_id)

      assert {:ok, %{"failure_kind" => "expired"}} = Delivery.delivery(f.scope, f.delivery_id)
      assert jobs("dlq_replay", f.delivery_id) == []
    end

    test "T-29 (3), (5): a replay opens a new attempt with a derived key and queues its job in dlq_replay",
         ctx do
      f = failed!(ctx)

      assert {:ok, {:replay_opened, 2}} =
               Delivery.replay_dead_letter(f.scope, f.dead_letter_id, job: &job/1)

      derived = DeadLetters.replay_key(f.key, f.dead_letter_id)
      assert derived =~ ~r/^rpl_[0-9a-f]{32}$/
      assert attempt_key(f.scope, f.delivery_id, 2) == derived

      assert %{
               "state" => "replaying",
               "replay_idempotency_key" => ^derived,
               "replay_attempt_no" => 2
             } =
               letter(f.scope, f.dead_letter_id)

      assert [[%{"attempt_no" => 2}]] = jobs("dlq_replay", f.delivery_id)

      assert {:ok, %{"failure_kind" => nil, "replay_depth" => 1}} =
               Delivery.delivery(f.scope, f.delivery_id)

      assert {:ok, {:not_open, nil}} =
               Delivery.replay_dead_letter(f.scope, f.dead_letter_id, job: &job/1)

      assert {:ok, []} = Delivery.rebuild_projection(f.scope, f.delivery_id)
    end

    test "T-29 (5): the derived key matches the vector" do
      {:ok, id} = Relay.Id.parse("0192f3a4-5b6c-7d8e-9f01-23456789abcd")
      assert DeadLetters.replay_key("pik-0001", id) == "rpl_ce82ff5b4d8768fc3e7eddf0557b84df"
      assert DeadLetters.replay_key(nil, id) == "rpl_365c16950ae2c94c8adae362a3eba7ae"
    end

    test "T-29 (4): a replayed delivery that fails again is not replayed a second time", ctx do
      f = failed!(ctx)

      {:ok, {:replay_opened, 2}} =
        Delivery.replay_dead_letter(f.scope, f.dead_letter_id, job: &job/1)

      {:ok, :started} = Delivery.start_attempt(f.scope, f.delivery_id, 2)

      failure =
        DeliveryFixture.failure(f.delivery_id, 2, ctx.parameters,
          failure_class: "quota",
          condition: nil
        )

      assert {:ok, {:applied, {:dead_letter, :exhausted, _}, {:recorded, second}}} =
               Delivery.fail_attempt(f.scope, failure)

      assert %{"state" => "replayed"} = letter(f.scope, f.dead_letter_id)

      assert %{"replay_depth" => 1, "replay_of_id" => replay_of} = letter(f.scope, second)
      assert replay_of == f.dead_letter_id

      assert {:ok, {:depth_exceeded, nil}} =
               Delivery.replay_dead_letter(f.scope, second, job: &job/1)
    end

    test "T-29, INV-3: a succeeded replay keeps its dead letter as replayed", ctx do
      f = failed!(ctx)

      {:ok, {:replay_opened, 2}} =
        Delivery.replay_dead_letter(f.scope, f.dead_letter_id, job: &job/1)

      {:ok, :started} = Delivery.start_attempt(f.scope, f.delivery_id, 2)

      {:applied, _} =
        DeliveryFixture.finish(f.scope, f.delivery_id, 2, :succeeded, delivery_rank: 1)

      assert %{"state" => "replayed"} = letter(f.scope, f.dead_letter_id)
      assert {:ok, :not_replaying} = Delivery.finish_replay(f.scope, f.dead_letter_id, true)
    end

    test "T-29: an operator closes an open dead letter with an audit record", ctx do
      f = failed!(ctx)

      assert {:ok, :closed} =
               Delivery.close_dead_letter(
                 f.scope,
                 f.dead_letter_id,
                 :operator,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert {:ok, :not_open} =
               Delivery.close_dead_letter(
                 f.scope,
                 f.dead_letter_id,
                 :operator,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert %{"state" => "closed", "close_reason" => "operator"} =
               letter(f.scope, f.dead_letter_id)

      assert {:ok, [%{"id" => id}]} =
               Delivery.list_dead_letters(f.scope,
                 states: ["closed"],
                 classes: [:exhausted],
                 channel: :email
               )

      assert id == f.dead_letter_id
      assert {:ok, []} = Delivery.list_dead_letters(f.scope, states: ["open"])
    end
  end

  describe "T-29 (6) automatic replay" do
    test "T-29 (6): a closed provider breaker replays the provider's recent exhausted dead letters",
         ctx do
      provider = "p" <> TenantFixture.random()
      a = failed!(ctx, delivery: [provider: provider])
      b = failed!(ctx, delivery: [provider: provider])
      other = failed!(ctx, delivery: [provider: "fcm"])
      assert DeadLetters.auto_replay_window_ms() == 30 * 60_000

      assert {:ok, []} =
               Delivery.auto_replay_candidates(
                 a.scope,
                 provider,
                 DateTime.add(DateTime.utc_now(), 60),
                 10
               )

      assert :ok = perform_job(provider)

      for f <- [a, b] do
        assert %{"state" => "replaying", "replay_actor_kind" => "system"} =
                 letter(f.scope, f.dead_letter_id)

        assert [[%{"attempt_no" => 2}]] = jobs("dlq_replay", f.delivery_id)
      end

      assert %{"state" => "open"} = letter(other.scope, other.dead_letter_id)
      assert :ok = perform_job(provider)
      assert [[_]] = jobs("dlq_replay", a.delivery_id)
    end

    test "T-29 (6): only a provider-level close queues the automatic replay" do
      provider = "p" <> TenantFixture.random()
      meta = %{level: :provider, provider: provider, from: :half_open, to: :closed}

      assert :ok =
               AutoReplay.handle_event(
                 [:relay, :breaker, :transition],
                 %{},
                 %{meta | level: :tenant_provider},
                 nil
               )

      assert :ok =
               AutoReplay.handle_event(
                 [:relay, :breaker, :transition],
                 %{},
                 %{meta | to: :open},
                 nil
               )

      assert :ok = AutoReplay.handle_event([:relay, :breaker, :transition], %{}, meta, nil)

      assert eventually(fn ->
               Repo.query!(
                 "SELECT count(*)::int FROM relay_queue.oban_jobs WHERE queue = 'maintenance' AND args->>'provider' = $1",
                 [provider]
               ).rows == [[1]]
             end)
    end
  end

  defp perform_job(provider), do: AutoReplay.perform(%Oban.Job{args: %{"provider" => provider}})

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
