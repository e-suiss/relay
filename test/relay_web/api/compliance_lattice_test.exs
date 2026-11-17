defmodule RelayWeb.Api.ComplianceLatticeTest do
  use Relay.DataCase, async: false

  alias Relay.Policy.IysGate
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  defmodule Gate do
    @moduledoc false

    @behaviour Relay.Policy.IysGate

    @impl Relay.Policy.IysGate
    def status(_scope, brand, channel, address_digest) do
      {pid, status} = Application.fetch_env!(:relay, __MODULE__)
      send(pid, {:iys_asked, brand, channel, is_binary(address_digest)})
      status
    end
  end

  @hour 3_600_000
  @wrap "SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1 LIMIT 1"
  @key "SELECT * FROM relay_fn.subject_key_create($1, $2, 'commercial_consent', $3, $4)"
  @consent "SELECT * FROM relay_fn.consent_record($1, $2, NULL, $3, 'active', $4, $5, 'access', 1, $6, $7, $8, $9, NULL, 'access', 'evt_1')"
  @preference "SELECT * FROM relay_fn.preference_set($1, $2, 'category_channel', $3, $4, 'opt_in', 'subscriber', 'acc_user_1')"
  @events "SELECT detail FROM relay.delivery_events WHERE delivery_id = $1"

  setup do
    previous = Application.get_env(:relay, IysGate)

    on_exit(fn ->
      Application.delete_env(:relay, Gate)

      if previous,
        do: Application.put_env(:relay, IysGate, previous),
        else: Application.delete_env(:relay, IysGate)
    end)

    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp gate!(status) do
    Application.put_env(:relay, Gate, {self(), status})
    Application.put_env(:relay, IysGate, impl: Gate)
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp marketing!(scope, token, channels) do
    F.workflow!(scope, token, "newsletter",
      category: "news",
      message_class: "marketing",
      channels: channels
    )
  end

  defp subscriber!(token, fields \\ %{}) do
    external_id = "user-" <> TenantFixture.random()

    body =
      Map.merge(
        %{
          "external_id" => external_id,
          "email" => "ayse@example.com",
          "timezone" => "Europe/Istanbul"
        },
        fields
      )

    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    external_id
  end

  defp recipient_id(scope, external_id) do
    {:ok, %{"_id" => id}} = Relay.Subscribers.fetch(scope, external_id)
    id
  end

  defp consent!(scope, external_id, channel, kind, type \\ "individual") do
    recipient = recipient_id(scope, external_id)
    [[wrap]] = sql!(scope, @wrap, [recipient])
    key_params = [Relay.Id.generate(), recipient, TenantFixture.digest(), wrap]
    [["created", key]] = sql!(scope, @key, key_params)

    params = [
      Relay.Id.generate(),
      recipient,
      channel,
      kind,
      type,
      Relay.Clock.utc_now(),
      TenantFixture.digest(),
      :crypto.strong_rand_bytes(48),
      key
    ]

    [["recorded", _id]] = sql!(scope, @consent, params)
  end

  defp opt_in!(scope, external_id, channel) do
    params = [Relay.Id.generate(), recipient_id(scope, external_id), "news", channel]
    [["set", _id, _version]] = sql!(scope, @preference, params)
  end

  defp send!(token, to, extra \\ %{}) do
    body =
      Map.merge(%{"workflow" => "newsletter", "to" => [to], "data" => %{"order" => "A-1"}}, extra)

    F.body(F.request(:post, "/v1/events", token, body), 202)
  end

  defp deliveries(token, accepted) do
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    Map.new(F.body(F.request(:get, path, token), 200)["data"], &{&1["channel"], &1})
  end

  defp delivery!(token, to, channel \\ "email"), do: deliveries(token, send!(token, to))[channel]

  defp now_ms, do: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

  describe "PC-27 PC-33 İYS at gate 1d" do
    test "PC-27, INV-19: a tenant of the Turkey region without İYS information sends no marketing e-mail",
         ctx do
      assert TenantFixture.region() == :tr
      marketing!(ctx.scope, ctx.token, ["email"])
      external_id = subscriber!(ctx.token)
      consent!(ctx.scope, external_id, "email", "explicit_opt_in")
      opt_in!(ctx.scope, external_id, "email")

      delivery = delivery!(ctx.token, external_id)

      assert %{"status" => "skipped", "reason" => "iys_not_configured"} = delivery
      assert delivery["rule_id"] == "iys.not_configured"
      assert F.delivery_jobs(delivery["id"]) == []
    end

    test "PC-27: informational classes and the other channels never ask İYS", ctx do
      gate!(:not_configured)
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["email"])
      marketing!(ctx.scope, ctx.token, ["email", "in_app"])
      external_id = subscriber!(ctx.token)
      consent!(ctx.scope, external_id, "email", "explicit_opt_in")

      body = %{
        "workflow" => "order-shipped",
        "to" => [external_id],
        "data" => %{"order" => "A-1"}
      }

      sent = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
      assert %{"email" => %{"status" => "queued"}} = deliveries(ctx.token, sent)
      refute_received {:iys_asked, _brand, _channel, _digest}

      by_channel = deliveries(ctx.token, send!(ctx.token, external_id))
      assert %{"status" => "skipped", "rule_id" => "iys.not_configured"} = by_channel["email"]
      assert %{"status" => "queued"} = by_channel["in_app"]
      assert_received {:iys_asked, nil, :email, true}
      refute_received {:iys_asked, _brand, _channel, _digest}
    end

    test "PC-33, PC-24: an individual needs an approval in a fresh İYS copy, a merchant only no rejection",
         ctx do
      marketing!(ctx.scope, ctx.token, ["email"])
      individual = subscriber!(ctx.token)
      consent!(ctx.scope, individual, "email", "explicit_opt_in")
      opt_in!(ctx.scope, individual, "email")

      gate!({:cached, :approved, now_ms()})
      assert %{"status" => "queued"} = delivery!(ctx.token, individual)

      gate!({:cached, :none, now_ms()})
      assert %{"rule_id" => "iys.approval_missing"} = delivery!(ctx.token, individual)

      gate!({:cached, :approved, now_ms() - 25 * @hour})
      stale = delivery!(ctx.token, individual)
      assert %{"status" => "skipped", "reason" => "iys_stale", "rule_id" => "iys.stale"} = stale

      merchant = subscriber!(ctx.token, %{"legal_type" => "merchant"})
      opt_in!(ctx.scope, merchant, "email")

      gate!({:cached, :none, now_ms()})
      assert %{"status" => "queued"} = delivery!(ctx.token, merchant)

      gate!({:cached, :rejected, now_ms()})
      assert %{"rule_id" => "iys.rejected"} = delivery!(ctx.token, merchant)
    end
  end

  describe "PC-40 the compliance table at gate 1d" do
    test "PC-58, PC-40: dry_run and the recorded decision carry the row that decided", ctx do
      scope = ctx.tenant.test
      token = F.token(scope)
      marketing!(scope, token, ["email"])
      external_id = subscriber!(token)

      dry = send!(token, external_id, %{"send_mode" => "dry_run"})
      assert [%{"decisions" => [decision]}] = dry["notifications"]
      assert %{"decision" => "skip", "rule_id" => "consent.missing"} = decision

      assert %{
               "compliance_row" => "tr.marketing.individual",
               "compliance_country" => "TR",
               "compliance_version" => 1,
               "required_consent" => "explicit_opt_in",
               "recipient_type" => "individual"
             } = decision["detail"]

      delivery = delivery!(token, external_id)
      assert delivery["rule_id"] == "consent.missing"
      {:ok, id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
      details = for [detail] <- sql!(scope, @events, [id]), is_map(detail), do: detail
      assert Enum.any?(details, &(&1["compliance_row"] == "tr.marketing.individual"))
    end

    test "PC-40, INV-17: the phone's calling code picks the row and a tenant refusal tightens it",
         ctx do
      gate!(:out_of_scope)
      marketing!(ctx.scope, ctx.token, ["email"])
      external_id = subscriber!(ctx.token, %{"phone" => "+4915112345678"})
      consent!(ctx.scope, external_id, "email", "soft_opt_in")
      opt_in!(ctx.scope, external_id, "email")

      place = sql!(ctx.scope, "SELECT calling_code FROM relay.recipient_addresses", [])
      assert ["49"] in place

      assert %{"status" => "queued"} = delivery!(ctx.token, external_id)

      refusals = [%{"country" => "EU", "consent_kinds" => ["soft_opt_in"]}]
      settings = F.request(:put, "/v1/compliance_settings", ctx.token, %{"refusals" => refusals})
      assert %{"version" => 1} = F.body(settings, 200)

      refused = delivery!(ctx.token, external_id)
      assert %{"status" => "skipped", "reason" => "consent_missing"} = refused
      assert refused["rule_id"] == "consent.insufficient"
    end

    test "PC-41: a recipient whose profile country has no row needs explicit opt-in on every channel",
         ctx do
      gate!(:out_of_scope)
      marketing!(ctx.scope, ctx.token, ["in_app"])
      japan = subscriber!(ctx.token, %{"country" => "JP"})
      turkey = subscriber!(ctx.token)

      view = F.body(F.request(:get, "/v1/subscribers/" <> japan, ctx.token), 200)
      assert view["country"] == "JP"

      missing = delivery!(ctx.token, japan, "in_app")
      assert %{"status" => "skipped", "rule_id" => "consent.missing"} = missing
      assert %{"status" => "queued"} = delivery!(ctx.token, turkey, "in_app")
    end

    test "WF-45: a device registration records the zone the device reported for the time zone chain",
         ctx do
      external_id = subscriber!(ctx.token)

      body = %{
        "platform" => "fcm",
        "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
        "app" => "com.example.shop",
        "permission" => "granted",
        "timezone" => "Europe/Berlin"
      }

      path = "/v1/subscribers/#{external_id}/devices"
      device = F.body(F.request(:post, path, ctx.token, body), 201)
      assert device["timezone"] == "Europe/Berlin"

      recipient = recipient_id(ctx.scope, external_id)

      {:ok, row} =
        Repo.in_scope(ctx.scope, fn _status -> Relay.Policy.Live.Store.recipient(recipient) end)

      assert %{"device_time_zone" => "Europe/Berlin", "timezone" => "Europe/Istanbul"} = row
      assert row["country"] == nil and row["calling_code"] == nil
    end
  end
end
