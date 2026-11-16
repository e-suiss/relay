defmodule Relay.Api.EventCorrelationTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Events
  alias Relay.Api.Queries
  alias Relay.Platform.Envelope
  alias Relay.Platform.OutboxStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @digest "sha256:" <> String.duplicate("a", 64)
  @item %{"ref" => "order-1", "version" => "3", "digest" => @digest}

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{scope: tenant.live}
  end

  defp accept!(scope, fields) do
    body =
      Map.merge(
        %{
          "workflow" => "order-shipped",
          "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
          "data" => %{"order" => "A-1"}
        },
        fields
      )

    {:ok, actor} = Relay.Actor.new(:api_client, "api_client", "api_client")
    ctx = %{scope: scope, actor: actor}
    {:ok, prepared} = Events.prepare(ctx, body)

    {:ok, {:ok, answer}} =
      Relay.Ingest.in_scope(scope, fn _status -> Events.accept(prepared, ctx) end)

    answer
  end

  defp uuid(external, prefix) do
    {:ok, id} = Relay.ExternalId.decode(external, [prefix])
    id
  end

  describe "E-83 E-85 item and correlation_id" do
    test "E-83: the sender's item and correlation_id are stored with the event and read back",
         ctx do
      answer = accept!(ctx.scope, %{"item" => @item, "correlation_id" => "work-42"})
      [%{"notification_id" => ntf}] = answer["notifications"]

      {:ok, {200, [], event}} = Queries.event(ctx.scope, uuid(answer["id"], "evt"))
      assert event["correlation_id"] == "work-42"
      assert event["item"] == @item

      {:ok, {200, [], notification}} =
        Queries.notification(ctx.scope, uuid(ntf, "ntf"), false)

      assert notification["correlation_id"] == "work-42"
      assert notification["item"] == @item
    end

    test "E-83: an event without them shows neither", ctx do
      answer = accept!(ctx.scope, %{})
      [%{"notification_id" => ntf}] = answer["notifications"]

      {:ok, {200, [], notification}} =
        Queries.notification(ctx.scope, uuid(ntf, "ntf"), false)

      refute Map.has_key?(notification, "correlation_id")
      refute Map.has_key?(notification, "item")
    end

    test "E-85: the envelope carries the issuer, the Access tenant and the correlationid", ctx do
      answer = accept!(ctx.scope, %{"correlation_id" => "work-42"})
      [%{"notification_id" => ntf}] = answer["notifications"]
      notification_id = Relay.Id.to_string(uuid(ntf, "ntf"))

      event = %{
        id: Relay.Id.generate(),
        created_at: ~U[2026-12-06 10:00:00.000000Z],
        event_type: "notification.delivered",
        stream_key: "notification:" <> notification_id,
        epoch: 1,
        seq: 3,
        payload: %{"notification_id" => notification_id, "recipient_kind" => "subscriber"},
        traceparent: nil
      }

      {:ok, context} =
        Relay.Repo.in_scope(ctx.scope, fn _status ->
          Envelope.context(event, "https://relay.example.com/")
        end)

      envelope = Envelope.build(event, context)

      assert envelope["source"] == "https://relay.example.com"
      assert envelope["correlationid"] == "work-42"
      assert envelope["environment"] == "live"
      assert is_binary(envelope["accesstenant"])
      refute Map.has_key?(envelope, "accessorganization")
      assert envelope["data"] == %{"notification_id" => ntf}
      assert "oev_" <> _ = envelope["id"]
      assert envelope["seq"] == 3

      {:ok, none} =
        Relay.Repo.in_scope(ctx.scope, fn _status -> OutboxStore.envelope_context(nil, nil) end)

      assert none["correlation_id"] == nil
      assert none["access_organization_id"] == nil
    end
  end
end
