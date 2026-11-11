defmodule Relay.EngagementTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @browser "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"

  defp forget do
    Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), "click_signals"})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp request(overrides \\ []) do
    Map.merge(
      %{
        method: "GET",
        ip: {203, 0, 113, 7},
        user_agent: @browser,
        headers: ["accept", "host", "user-agent"],
        at_ms: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)
      },
      Map.new(overrides)
    )
  end

  defp rank(scope, id) do
    {:ok, %{"delivery_rank" => rank}} = Relay.Delivery.delivery(scope, id)
    rank
  end

  defp last(scope, id) do
    {:ok, ledger} = Relay.Delivery.ledger(scope, id)
    List.last(ledger)
  end

  describe "DS-30 DS-31 DS-34 clicks" do
    test "DS-34: a human click is the user's delivery evidence and raises the delivery" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      click = %{scope: scope, delivery_id: id, link: 1}

      assert {:ok, {:applied, :human, nil}} = Relay.Engagement.record_click(click, request())
      assert rank(scope, id) == 2
      assert %{"actor" => "user", "event_type" => "engagement.clicked"} = last(scope, id)
    end

    test "DS-30, DS-31: a likely bot click is recorded by Relay and is no evidence" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      click = %{scope: scope, delivery_id: id, link: 1}
      bot = request(user_agent: "curl/8.9.1")

      assert {:ok, {_result, :likely_bot, "user_agent"}} =
               Relay.Engagement.record_click(click, bot)

      assert rank(scope, id) == 0
      assert %{"actor" => "relay", "event_type" => "engagement.clicked"} = last(scope, id)
    end

    test "DS-52: the third distinct link of a message within ten seconds is a burst" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      at = request().at_ms

      for {link, offset} <- [{1, -4_000}, {2, -2_000}] do
        click = %{scope: scope, delivery_id: id, link: link}

        assert {:ok, {_result, :human, nil}} =
                 Relay.Engagement.record_click(click, request(at_ms: at + offset))
      end

      third = %{scope: scope, delivery_id: id, link: 3}

      assert {:ok, {_result, :likely_bot, "burst"}} =
               Relay.Engagement.record_click(third, request())
    end
  end

  describe "DS-32 DS-33 opens" do
    test "DS-32: an open is recorded with its machine open flag and never raises delivery" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      open = %{scope: scope, delivery_id: id}

      assert {:ok, {_result, false}} = Relay.Engagement.record_open(open, request())
      proxy = request(user_agent: "Mozilla/5.0 (via ggpht.com GoogleImageProxy)")
      assert {:ok, {_result, true}} = Relay.Engagement.record_open(open, proxy)
      assert rank(scope, id) == 0
      assert %{"actor" => "relay", "event_type" => "engagement.opened"} = last(scope, id)
    end
  end
end
