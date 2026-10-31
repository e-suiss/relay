defmodule Relay.Tenancy.AccessSecurityPauseTest do
  use Relay.SqlCase, async: false

  @tenant "SELECT * FROM relay_ops.tenant_create($1, $2, $3, 'general', 'Europe/Istanbul', 'tr', NULL, $4, $5, $6, $7, $8, $9)"
  @accept "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, NULL, $3, $4, NULL, 'system', NULL, NULL, NULL, false, NULL)"
  @pause "SELECT relay_fn.delivery_pause($1, 'killswitch.off', $2)"
  @claimed "SELECT event_type, stream_key, payload FROM relay_fn.outbox_claim(100)"
  @fields ~w(channel delivery_id kill_switch_id notification_id paused_at reason rule_id status)
  @others [{"access", "transactional"}, {nil, "security"}, {"pay", "security"}]

  defp delivery_in!(product, class) do
    tenant = id()
    access_tenant = "acc_" <> Base.encode16(tenant)

    ["created", ^tenant] =
      row(@tenant, [tenant, access_tenant, region(), product, digest() | actor()])

    "active" = ctx(tenant)
    _data_key = tenant_key!("data")
    wrap_key = tenant_key!("dek_wrap")
    recipient = recipient!(blind_index_key!(), wrap_key)
    notification = id()

    ["created", ^notification] =
      row(@accept, [notification, recipient, "dedup:" <> Base.encode16(digest()), class])

    delivery!(notification)
  end

  defp announced(delivery) do
    stream = "delivery:" <> Ecto.UUID.load!(delivery)
    for [type, ^stream, payload] <- rows(@claimed), do: {type, payload}
  end

  describe "TN-42 security stop of Access messages" do
    test "TN-42, E-70: each paused Access security delivery returns its status to Access through the outbox" do
      delivery = delivery_in!("access", "security")
      kill_switch = id()

      assert "paused" = one(@pause, [delivery, kill_switch])
      assert "already_paused" = one(@pause, [delivery, kill_switch])

      assert [{"delivery.paused", payload}] = announced(delivery)
      assert payload["delivery_id"] == Ecto.UUID.load!(delivery)
      assert payload["kill_switch_id"] == Ecto.UUID.load!(kill_switch)
      assert payload["rule_id"] == "killswitch.off"
      assert payload["status"] == "queued"
      assert payload["reason"] == "paused"
      assert payload["channel"] == "sms"
      assert is_binary(payload["notification_id"]) and is_binary(payload["paused_at"])

      assert Enum.sort(Map.keys(payload)) == @fields
    end

    test "TN-42: a pause of another class or another tenant announces nothing" do
      for {product, class} <- @others do
        delivery = delivery_in!(product, class)
        assert "paused" = one(@pause, [delivery, id()])
        assert announced(delivery) == []
      end
    end
  end
end
