defmodule Relay.Channels.EmailIntakeTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.EmailIntake
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  defp forget do
    for name <- ["channel_event_evidence", "email_bounce_codes"] do
      Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
    end
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp bounce(delivery_id, type, details) do
    %{
      "RecordType" => "Bounce",
      "Type" => type,
      "ID" => 7,
      "MessageID" => "pm-1",
      "Email" => "bounced@example.com",
      "Details" => details,
      "BouncedAt" => "2026-11-05T10:00:00Z",
      "Metadata" => %{"relay_delivery_id" => Relay.Id.to_string(delivery_id)}
    }
  end

  defp suppressions(scope, reason) do
    {:ok, rows} = Relay.Preferences.list_suppressions(scope, %{reason: reason}, nil, 10)
    rows
  end

  describe "CH-39 CH-40 DS-10 provider e-mail events" do
    test "CH-40, DS-10: a hard bounce is recorded on its delivery and suppresses the address" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      body = bounce(id, "HardBounce", "smtp;550 5.1.1 user unknown")
      events = Relay.Channels.email_events("postmark", body)

      assert {:ok, [{:recorded, _result, actions}]} = EmailIntake.ingest(scope, events)
      assert {:suppress, "hard_bounce", nil} in actions
      assert {:ok, %{"failure_kind" => "bounced"}} = Relay.Delivery.delivery(scope, id)
      assert [_suppression] = suppressions(scope, "hard_bounce")
    end

    test "CH-39: a sender configuration bounce is recorded and suppresses no one" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      body = bounce(id, "DMARCPolicy", "smtp;550 5.7.26 unauthenticated mail")
      events = Relay.Channels.email_events("postmark", body)

      assert {:ok, [{:recorded, _result, actions}]} = EmailIntake.ingest(scope, events)
      refute Enum.any?(actions, &match?({:suppress, _reason, _expires}, &1))
      assert suppressions(scope, "hard_bounce") == []
    end

    test "CH-47: an event that names no known delivery is skipped" do
      %{scope: scope} = DeliveryFixture.sendable!()

      unnamed = Relay.Channels.email_events("sendgrid", [%{"event" => "delivered"}])
      assert {:ok, [{:skipped, :no_delivery}]} = EmailIntake.ingest(scope, unnamed)

      unknown = bounce(Relay.Id.generate(), "HardBounce", "smtp;550 5.1.1 user unknown")
      events = Relay.Channels.email_events("postmark", unknown)
      assert {:ok, [{:skipped, :delivery_not_found}]} = EmailIntake.ingest(scope, events)
    end
  end
end
