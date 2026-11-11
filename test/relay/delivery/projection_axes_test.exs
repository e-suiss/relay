defmodule Relay.Delivery.ProjectionAxesTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  defp forget,
    do:
      Datasets.Cache.invalidate(
        Datasets.Cache,
        {Datasets.installation_scope(), "channel_event_evidence"}
      )

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    DeliveryFixture.sendable!()
  end

  defp append(scope, id, attrs) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        Map.merge(
          %{
            id: Relay.Id.generate(),
            delivery_id: id,
            actor: :provider_webhook,
            provider: "fake",
            event_type: "provider.reported",
            occurred_at: Relay.Clock.utc_now()
          },
          Map.new(attrs)
        )
      )

    {:ok, {result, _rank, _version}} = Relay.Delivery.append_ledger(scope, entry)
    result
  end

  defp delivery(scope, id) do
    {:ok, delivery} = Relay.Delivery.delivery(scope, id)
    delivery
  end

  defp event(id, code),
    do: %{delivery_id: id, provider: "fake", channel: "email", event_code: code}

  defp ago(seconds), do: DateTime.add(Relay.Clock.utc_now(), -seconds, :second)

  describe "DS-4 failure reduction" do
    test "DS-4: for one attempt and kind the provider webhook outranks the provider API", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)
      at = ago(60)
      failed = [attempt_no: attempt, failure_kind: :failed, occurred_at: at]

      assert append(scope, id, failed ++ [failure_class: "permanent_target"]) == :applied

      assert append(scope, id, failed ++ [actor: :provider_api, failure_class: "transient"]) ==
               :stale_ignored

      assert %{"failure_class" => "permanent_target", "failure_actor" => "provider_webhook"} =
               delivery(scope, id)

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-4: a webhook report replaces the API's report of the same failure", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)
      failed = [attempt_no: attempt, failure_kind: :failed, occurred_at: ago(60)]

      assert append(scope, id, failed ++ [actor: :provider_api, failure_class: "transient"]) ==
               :applied

      assert append(scope, id, failed ++ [failure_class: "permanent_target"]) == :applied
      assert %{"status" => "failed", "failure_class" => "permanent_target"} = delivery(scope, id)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end

  describe "INV-8 DS-5 DS-6 outcome over every attempt" do
    test "INV-8, DS-5: a second attempt's delivered is visible as duplicate_delivered", %{
      scope: scope,
      delivery_id: id
    } do
      first = DeliveryFixture.started_attempt!(scope, id)
      {:applied, _} = DeliveryFixture.finish(scope, id, first, :unknown)
      second = DeliveryFixture.started_attempt!(scope, id)

      assert append(scope, id, attempt_no: second, delivery_rank: :delivered) == :applied
      assert append(scope, id, attempt_no: first, delivery_rank: :delivered) == :applied

      assert %{"status" => "delivered", "duplicate_delivered" => true, "late_event_count" => 1} =
               delivery(scope, id)

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-6, DS-17: an email bounce after delivery fails it and keeps delivered_at", %{
      scope: scope,
      delivery_id: id
    } do
      _attempt = DeliveryFixture.started_attempt!(scope, id)
      assert {:ok, %{result: :applied}} = Live.record_event(scope, event(id, "delivered"))
      %{"delivered_at" => delivered_at} = delivery(scope, id)

      assert {:ok, %{result: :applied}} = Live.record_event(scope, event(id, "bounced"))

      assert %{"status" => "failed", "delivery_rank" => 2, "delivered_at" => ^delivered_at} =
               delivery(scope, id)

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-6, DS-5: a conflicting failure after delivery flags the delivery", %{
      scope: scope,
      delivery_id: id
    } do
      _attempt = DeliveryFixture.started_attempt!(scope, id)
      assert {:ok, %{result: :applied}} = Live.record_event(scope, event(id, "delivered"))

      assert {:ok, %{result: :conflict_flagged}} =
               Live.record_event(scope, event(id, "undelivered"))

      assert %{"status" => "delivered", "has_conflict" => true} = delivery(scope, id)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end

  describe "DS-3 DS-7 the engagement axis" do
    test "DS-3, DS-7: each engagement keeps its first stamp and source; a human click wins", %{
      scope: scope,
      delivery_id: id
    } do
      click = fn by, at ->
        engagement = %{kind: :clicked, source: :tracked_link, clicked_by: by}
        append(scope, id, actor: :user, occurred_at: at, engagement: engagement)
      end

      assert click.(:likely_bot, ago(300)) == :applied
      assert click.(:human, ago(200)) == :applied
      assert click.(:likely_bot, ago(400)) == :stale_ignored
      assert click.(:human, ago(250)) == :applied

      assert %{"clicked_by" => "human", "clicked_source" => "tracked_link", "clicked_at" => at} =
               delivery(scope, id)

      assert DateTime.diff(ago(250), at, :second) in 0..2
      assert %{"clicked_by" => "human"} = Relay.Delivery.engagement(delivery(scope, id))
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-7, DS-8: a read proves its own delivery and keeps its source", %{
      scope: scope,
      delivery_id: id
    } do
      read = %{kind: :read, source: :client_sdk}
      result = append(scope, id, actor: :client_sdk, delivery_rank: :delivered, engagement: read)
      assert result == :applied

      assert %{"status" => "delivered", "read_source" => "client_sdk", "seen_at" => nil} =
               delivery(scope, id)

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end

  describe "DS-10 unknown provider codes" do
    test "DS-10, DS-46: an event code without evidence is only written to the ledger", %{
      scope: scope,
      delivery_id: id
    } do
      %{"projection_version" => version} = delivery(scope, id)

      assert Live.record_event(scope, Map.put(event(id, "teleported"), :raw_code, "X-42")) ==
               {:error, :unknown_event}

      assert %{"projection_version" => ^version, "status" => "queued"} = delivery(scope, id)
      {:ok, ledger} = Relay.Delivery.ledger(scope, id)

      assert %{"raw_code" => "X-42", "detail" => %{"event_code" => "teleported"}} =
               Enum.find(ledger, &(&1["event_type"] == "provider.unknown_code"))

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end
end
