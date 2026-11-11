defmodule Relay.Workflow.DigestWindowTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Digest.Schedule
  alias Relay.Workflow.Digest.Window
  alias Relay.Workflow.Span

  @t0 ~U[2026-11-02 08:00:00Z]

  defp config!(step) do
    {:ok, config} = Window.config(step)
    config
  end

  defp state(first_s, last_s, count) do
    %{
      first_at: DateTime.add(@t0, first_s, :second),
      last_at: DateTime.add(@t0, last_s, :second),
      item_count: count
    }
  end

  describe "WF-26 window model" do
    test "WF-26: a sliding window fires at min(last + debounce, first + max_wait)" do
      config = config!(%{"mode" => "sliding", "debounce" => "PT30S", "max_wait" => "PT5M"})

      assert Window.fire_at(config, state(0, 0, 1), nil) == DateTime.add(@t0, 30, :second)
      assert Window.fire_at(config, state(0, 100, 4), nil) == DateTime.add(@t0, 130, :second)
      assert Window.fire_at(config, state(0, 290, 9), nil) == DateTime.add(@t0, 300, :second)
    end

    test "WF-26: a fixed window lasts max_wait from its first event" do
      config = config!(%{"mode" => "fixed", "max_wait" => "PT10M"})
      assert Window.fire_at(config, state(0, 500, 3), nil) == DateTime.add(@t0, 600, :second)
    end

    test "WF-26: reaching max_items fires the window at its last event" do
      step = %{"mode" => "fixed", "max_wait" => "PT1H", "max_items" => 3}
      config = config!(step)

      assert Window.fire_at(config, state(0, 20, 2), nil) == DateTime.add(@t0, 3_600, :second)
      assert Window.fire_at(config, state(0, 20, 3), nil) == DateTime.add(@t0, 20, :second)
    end

    test "WF-26: a scheduled window fires at the next local occurrence of its schedule" do
      config = config!(%{"mode" => "scheduled", "schedule" => "FREQ=DAILY;BYHOUR=9;BYMINUTE=30"})

      assert Window.fire_at(config, state(0, 0, 1), "Europe/Istanbul") ==
               ~U[2026-11-03 06:30:00Z]

      weekly = config!(%{"mode" => "scheduled", "schedule" => "FREQ=WEEKLY;BYDAY=FR;BYHOUR=17"})

      assert Window.fire_at(weekly, state(0, 0, 1), "Europe/Istanbul") ==
               ~U[2026-11-06 14:00:00Z]
    end

    test "WF-26: the fields of a digest step are checked with pointers" do
      assert {:error, errors} = Window.config(%{"mode" => "sliding"}, "/steps/0")

      pointers = errors |> Enum.map(& &1.pointer) |> Enum.sort()
      assert pointers == ["/steps/0/debounce", "/steps/0/max_wait"]

      assert {:error, [%{pointer: "/max_items", code: "out_of_range"}]} =
               Window.config(%{"mode" => "fixed", "max_wait" => "PT1M", "max_items" => 1})

      assert {:error, [%{pointer: "/schedule", code: "invalid_format"}]} =
               Window.config(%{"mode" => "scheduled", "schedule" => "FREQ=HOURLY"})

      assert {:error, [%{pointer: "/leading"}]} =
               Window.config(%{"mode" => "fixed", "max_wait" => "PT1M", "leading" => "first"})

      assert {:ok, %{leading: :immediate, max_items: 1000}} =
               Window.config(%{
                 "mode" => "fixed",
                 "max_wait" => "PT1M",
                 "leading" => "immediate",
                 "max_items" => 1000
               })
    end
  end

  describe "WF-37 INV-32 finite windows" do
    test "WF-37: a window field longer than 31 days is refused" do
      assert {:error, [%{pointer: "/max_wait", code: "out_of_range"}]} =
               Window.config(%{"mode" => "fixed", "max_wait" => "P32D"})

      assert {:ok, _config} = Window.config(%{"mode" => "fixed", "max_wait" => "P31D"})
    end

    test "INV-32: no window fires after 31 days from its first event" do
      config = %{config!(%{"mode" => "fixed", "max_wait" => "PT1M"}) | max_wait_ms: nil}
      config = Map.put(config, :release_at, DateTime.add(@t0, 40, :day))
      assert Window.fire_at(config, state(0, 0, 1), nil) == DateTime.add(@t0, 31, :day)
      assert Window.max_open_ms() == 31 * 86_400_000
    end
  end

  describe "WF-28 WF-31 classes and defaults" do
    test "WF-28, E-11: security, transactional and action_required are never digested" do
      for class <- ~w(security transactional action_required),
          do: assert(Window.exempt?(class))

      assert Window.exempt?(:security)
      refute Window.exempt?("social")
      refute Window.exempt?("operational")
      refute Window.exempt?("marketing")
    end

    test "WF-31: every default window is a valid digest step" do
      for {use, step} <- Window.defaults(), step["mode"] != "scheduled" do
        assert {:ok, %{mode: :sliding}} = Window.config(step), use
      end

      assert %{"debounce" => "PT30S", "max_wait" => "PT5M"} = Window.defaults()["direct_message"]
      assert %{"debounce" => "PT5M", "max_wait" => "PT1H"} = Window.defaults()["comment"]
    end
  end

  describe "WF-29 render data" do
    test "WF-29: the template sees the running total, the actors and at most 50 first and last activities" do
      items = for n <- 1..60, do: %{notification_id: n, delivery_id: nil, occurred_at: @t0}
      window = %{cumulative_count: 8, item_count: 3, window_key: <<1::256>>}
      data = Window.render(window, %{first: items, last: items, actors: 2}, 70)

      assert data["total_activities"] == 8
      assert data["window_activities"] == 3
      assert data["total_actors"] == 2
      assert length(data["first_activities"]) == 50
      assert hd(data["first_activities"])["notification_id"] == 1
      assert List.last(data["last_activities"])["notification_id"] == 60
      assert data["collapse_key"] == Base.encode16(<<1::256>>, case: :lower)
    end
  end

  describe "PC-46 morning burst" do
    test "PC-46, WF-42: held-back deliveries are released with the deterministic jitter of their recipient" do
      scope = Relay.Scope.new!(Relay.Id.generate(), :live)
      recipient = Relay.Id.generate()
      ends = ~U[2026-11-02 05:00:00Z]
      at = Window.release_at(scope, recipient, ends, "Europe/Istanbul", 900_000)

      assert at == Window.release_at(scope, recipient, ends, "Europe/Istanbul", 900_000)
      assert DateTime.diff(at, ends, :millisecond) in 0..899_999
      assert Window.release_at(scope, recipient, ends, "Europe/Istanbul", 0) == ends

      config = Window.release(at)
      assert Window.fire_at(config, state(0, 0, 4), nil) == at
    end
  end

  describe "WF-45 schedule subset" do
    test "WF-45: the DAILY and WEEKLY subset parses and other parts are refused" do
      assert {:ok, %{freq: :daily, hour: 9, minute: 0}} = Schedule.parse("FREQ=DAILY;BYHOUR=9")

      assert {:ok, %{freq: :weekly, days: [1, 4]}} =
               Schedule.parse("FREQ=WEEKLY;BYDAY=TH,MO;BYHOUR=8;BYMINUTE=15;INTERVAL=1")

      for text <- [
            "FREQ=MONTHLY;BYHOUR=9",
            "FREQ=DAILY",
            "FREQ=DAILY;BYHOUR=24",
            "FREQ=DAILY;BYHOUR=9;INTERVAL=2",
            "FREQ=DAILY;BYHOUR=9;BYDAY=MO",
            "FREQ=WEEKLY;BYDAY=1MO;BYHOUR=9",
            "FREQ=DAILY;BYHOUR=9,10",
            "FREQ=DAILY;BYHOUR=9;COUNT=3"
          ],
          do: assert(Schedule.parse(text) == :error, text)
    end

    test "WF-45: a local time skipped by a daylight saving gap falls after the gap" do
      {:ok, rule} = Schedule.parse("FREQ=DAILY;BYHOUR=2;BYMINUTE=30")
      at = Schedule.next(rule, ~U[2026-03-28 12:00:00Z], "Europe/Berlin")
      assert at == ~U[2026-03-29 01:00:00Z]
    end

    test "WF-45: the next occurrence is strictly after the instant" do
      {:ok, rule} = Schedule.parse("FREQ=DAILY;BYHOUR=9")
      assert Schedule.next(rule, ~U[2026-11-02 09:00:00Z], "Etc/UTC") == ~U[2026-11-03 09:00:00Z]
    end
  end

  describe "WF-37 durations" do
    test "WF-37: durations are fixed-length ISO 8601 durations" do
      assert Span.ms("PT30S") == {:ok, 30_000}
      assert Span.ms("P1W2DT3H") == {:ok, (9 * 24 + 3) * 3_600_000}
      assert Span.ms("PT0S") == :error
      assert Span.ms("P1M") == :error
      assert Span.ms(30) == :error
    end
  end
end
