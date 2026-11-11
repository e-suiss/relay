defmodule Relay.Workflow.DigestTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias RelayTest.TenantFixture

  defmodule Sink do
    @moduledoc false
    @behaviour Relay.Workflow.Digest.Sink

    @impl true
    def digest_ready(_scope, outcome) do
      send(self(), {:digest, outcome})
      :ok
    end
  end

  @sliding %{"mode" => "sliding", "debounce" => "PT30S", "max_wait" => "PT5M"}
  @minutes_6 6 * 60_000

  setup do
    previous = Application.get_env(:relay, Relay.Workflow.Digest, [])
    Application.put_env(:relay, Relay.Workflow.Digest, sink: Sink)
    on_exit(fn -> Application.put_env(:relay, Relay.Workflow.Digest, previous) end)

    tenant = TenantFixture.tenant!()
    scope = tenant.test
    keys = TenantFixture.keys!(scope)
    recipient = TenantFixture.recipient!(scope, keys)
    social = for _ <- 1..4, do: TenantFixture.notification(recipient, message_class: :social)
    request = TenantFixture.accept_request(social, data_key: keys.data)
    {:ok, _} = Relay.Ingest.accept(scope, request)

    %{scope: scope, recipient: recipient, ids: Enum.map(social, & &1.id)}
  end

  defp in_scope(ctx, fun) do
    {:ok, result} = Relay.Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    result
  end

  defp add(ctx, id, extra \\ %{}) do
    base = %{
      recipient_id: ctx.recipient,
      notification_id: id,
      message_class: "social",
      scope_ref: "workflow:comments:digest",
      key: "thread-1",
      step: @sliding
    }

    attrs = Map.merge(base, extra)
    in_scope(ctx, fn -> Relay.Workflow.digest_add(ctx.scope, attrs) end)
  end

  defp fire(ctx, window), do: Relay.Workflow.digest_fire(ctx.scope, window)

  defp read(ctx, id), do: Relay.Workflow.digest_read(ctx.scope, ctx.recipient, id)

  defp advance!(ctx, ms) do
    actor = TenantFixture.actor()
    digest = TenantFixture.digest()
    {:ok, {:advanced, _, _}} = Relay.Platform.VirtualClock.advance(ctx.scope, ms, digest, actor)
  end

  defp timers do
    query =
      from(j in Oban.Job,
        where: j.worker == "Relay.Workflow.Digest.Timer",
        select: j.args["window_id"]
      )

    Relay.Repo.all(query, prefix: "relay_queue", oban: true)
  end

  describe "WF-26 WF-27 windows" do
    test "WF-26, WF-27: the first event anchors the window, the next ones fold into it and the timer fires one digest",
         ctx do
      [a, b, c | _] = ctx.ids

      assert {:ok, %{role: :anchor, window_id: window}} = add(ctx, a, %{actor: "user-1"})
      assert {:ok, %{role: :folded, window_id: ^window}} = add(ctx, b, %{actor: "user-2"})
      assert {:ok, %{role: :folded, window_id: ^window}} = add(ctx, c, %{actor: "user-1"})
      assert {:ok, %{role: :anchor, window_id: ^window}} = add(ctx, a)
      assert Relay.Id.to_string(window) in timers()

      assert {:ok, :not_due} = fire(ctx, window)
      refute_received {:digest, _}

      advance!(ctx, @minutes_6)
      assert {:ok, {:digest, info}} = fire(ctx, window)
      assert_received {:digest, {:digest, ^info}}

      assert %{notification_id: ^a, window_id: ^window, render: render} = info
      assert %{"total_activities" => 3, "window_activities" => 3, "total_actors" => 2} = render
      assert Enum.map(render["first_activities"], & &1["notification_id"]) == [a, b, c]
      assert {:ok, :not_open} = fire(ctx, window)
    end

    test "WF-27: a window of one event hands over the event itself for its singular template",
         ctx do
      [a | _] = ctx.ids
      {:ok, %{role: :anchor, window_id: window}} = add(ctx, a)
      advance!(ctx, @minutes_6)

      assert {:ok, {:single, %{notification_id: ^a}}} = fire(ctx, window)
    end

    test "WF-26: with leading immediate the first event goes alone and the next one anchors",
         ctx do
      [a, b | _] = ctx.ids
      leading = %{step: Map.put(@sliding, "leading", "immediate")}

      assert {:ok, %{role: :sent_alone, window_id: window}} = add(ctx, a, leading)
      assert {:ok, %{role: :anchor, window_id: ^window}} = add(ctx, b, leading)
      advance!(ctx, @minutes_6)

      assert {:ok, {:single, %{notification_id: ^b}}} = fire(ctx, window)
    end

    test "WF-27: a read signal cancels the pending window and tells the anchor's run", ctx do
      [a, b | _] = ctx.ids
      {:ok, %{window_id: window}} = add(ctx, a)
      add(ctx, b)

      assert {:ok, [{^window, :cancelled}]} = read(ctx, b)
      assert_received {:digest, {:cancelled, %{notification_id: ^a, window_id: ^window}}}
      advance!(ctx, @minutes_6)
      assert {:ok, :not_open} = fire(ctx, window)
    end

    test "INV-3: the virtual clock tick fires what fell due", ctx do
      [a, b | _] = ctx.ids
      {:ok, %{window_id: window}} = add(ctx, a)
      add(ctx, b)

      assert :ok = Relay.Workflow.run_due_digests(ctx.scope)
      refute_received {:digest, _}
      advance!(ctx, @minutes_6)
      assert :ok = Relay.Workflow.run_due_digests(ctx.scope)
      assert_received {:digest, {:digest, %{window_id: ^window}}}
    end
  end

  describe "WF-28 WF-30 PC-46 routing" do
    test "WF-28, E-11: security, transactional and action_required are not digested", ctx do
      [a | _] = ctx.ids

      for class <- ~w(security transactional action_required) do
        assert {:error, %Relay.Error{code: :digest_exempt_class}} =
                 add(ctx, a, %{message_class: class})
      end
    end

    test "WF-26: a scheduled window needs the recipient's time zone", ctx do
      [a, b | _] = ctx.ids
      step = %{"mode" => "scheduled", "schedule" => "FREQ=DAILY;BYHOUR=9"}

      assert {:error, %Relay.Error{code: :validation_failed}} = add(ctx, a, %{step: step})

      zoned = %{step: step, time_zone: "Europe/Istanbul", key: "daily"}
      assert {:ok, %{role: :anchor, fire_at: %DateTime{}}} = add(ctx, b, zoned)
    end

    test "WF-30: past the density threshold the further events of the category are digested",
         ctx do
      [a, b, c | _] = ctx.ids

      density = fn id ->
        attrs = %{
          recipient_id: ctx.recipient,
          notification_id: id,
          message_class: "social",
          category: "comments",
          ref: Relay.Id.to_string(id),
          threshold: %{"limit" => 2, "window" => "PT10M"},
          step: @sliding
        }

        in_scope(ctx, fn -> Relay.Workflow.digest_density(ctx.scope, attrs) end)
      end

      assert {:ok, :under} = density.(a)
      assert {:ok, :under} = density.(b)
      assert {:ok, %{role: :anchor}} = density.(c)
      assert {:ok, %{role: :anchor}} = density.(c)
    end

    test "PC-46: social deliveries held back by quiet hours share one window released at the jittered end",
         ctx do
      [a, b | _] = ctx.ids
      release = DateTime.add(DateTime.utc_now(), 3_600, :second)

      quiet = fn id, class ->
        attrs = %{
          recipient_id: ctx.recipient,
          notification_id: id,
          message_class: class,
          category: "comments",
          channel: "push",
          release_at: release
        }

        in_scope(ctx, fn -> Relay.Workflow.digest_quiet_hours(ctx.scope, attrs) end)
      end

      assert {:ok, %{role: :anchor, window_id: window, fire_at: fire_at}} = quiet.(a, "social")
      assert {:ok, %{role: :folded, window_id: ^window}} = quiet.(b, "social")
      assert DateTime.compare(fire_at, release) == :eq
      assert {:ok, :not_applicable} = quiet.(a, "operational")
    end
  end
end
