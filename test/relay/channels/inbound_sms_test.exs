defmodule Relay.Channels.InboundSmsTest.OutsideIys do
  @behaviour Relay.Policy.IysGate

  @impl Relay.Policy.IysGate
  def status(_scope, _brand, _channel, _address_digest), do: :out_of_scope
end

defmodule Relay.Channels.InboundSmsTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Channels.Live.Receipts
  alias Relay.Compliance.Refusals.SinkWorker
  alias Relay.Datasets
  alias Relay.Policy.IysGate
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @stub Relay.Channels.ProviderHttp
  @datasets ["channel_event_evidence", "email_bounce_codes"]
  @worker "Relay.Channels.Live.ReceiptWorker"
  @token "token-1"
  @number "908501112233"
  @phone "+905551112233"
  @american "+12025550123"

  @refusals "SELECT channel::text, source, scope FROM relay.refusals WHERE recipient_id = $1"
  @consents "SELECT channel::text, status, writer, source FROM relay.consents WHERE recipient_id = $1 ORDER BY source_sequence, id"
  @preference "SELECT result FROM relay_fn.preference_set($1, $2, 'category_channel', 'news', $3, 'opt_in', 'subscriber', 'acc_user_1')"

  defp forget do
    for name <- @datasets,
        do: Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    gate = Application.get_env(:relay, IysGate)
    Application.put_env(:relay, IysGate, impl: __MODULE__.OutsideIys)

    on_exit(fn ->
      forget()

      if gate,
        do: Application.put_env(:relay, IysGate, gate),
        else: Application.delete_env(:relay, IysGate)
    end)

    tenant = TenantFixture.tenant!()
    scope = tenant.live
    account_id = account!(scope)
    sender!(scope, account_id)
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, conn.request_path, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "20210")
    end)

    %{
      scope: scope,
      token: F.token(scope),
      account_id: account_id,
      account: %{"id" => account_id, "provider" => "verimor"}
    }
  end

  defp account!(scope) do
    attrs = %{
      id: Relay.Id.generate(),
      channel: "sms",
      provider: "verimor",
      ownership: "shared",
      role: "primary",
      priority: 0,
      in_installation: true,
      transfer_basis: "none"
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    attrs.id
  end

  defp sender!(scope, account_id) do
    attrs = %{
      id: Relay.Id.generate(),
      provider_account_id: account_id,
      channel: "sms",
      kind: "sms_sender",
      value: @number,
      approval_state: "approved"
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_sender_identity(
        scope,
        attrs,
        TenantFixture.digest(),
        TenantFixture.actor()
      )
  end

  defp subscriber!(ctx, phone, fields \\ %{}) do
    external_id = "user-" <> TenantFixture.random()

    body =
      Map.merge(
        %{"external_id" => external_id, "phone" => phone, "timezone" => "Europe/Istanbul"},
        fields
      )

    F.body(F.request(:post, "/v1/subscribers", ctx.token, body), 201)
    {:ok, %{"_id" => recipient_id}} = Relay.Subscribers.fetch(ctx.scope, external_id)
    {external_id, recipient_id}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp message(id, from, text, at \\ "2026-11-17 13:00:00") do
    Jason.encode!([
      %{
        "type" => "inbound",
        "message_id" => id,
        "source_addr" => String.trim_leading(from, "+"),
        "destination_addr" => @number,
        "content" => text,
        "received_at" => at
      }
    ])
  end

  defp receive!(ctx, body, token \\ @token) do
    request = %{
      body: body,
      headers: [],
      url: "https://relay.test/inbound/v1/providers/x",
      token: token,
      now: Relay.Clock.utc_now()
    }

    Live.accept_provider_webhook(ctx.scope, ctx.account, Relay.Redacted.wrap(@token), request)
  end

  defp receipt_ids(ctx) do
    for [text] <- F.jobs(@worker, ctx.scope, "receipt_ids"), id <- Jason.decode!(text) do
      {:ok, parsed} = Relay.Id.parse(id)
      parsed
    end
  end

  defp process!(ctx), do: Receipts.process(ctx.scope, receipt_ids(ctx))

  defp states(ctx) do
    {:ok, rows} =
      Repo.in_scope(ctx.scope, fn _status ->
        Enum.map(receipt_ids(ctx), &Relay.Webhooks.receipt/1)
      end)

    rows |> Enum.map(& &1["state"]) |> Enum.uniq()
  end

  defp take!(ctx, id, from, text, at \\ "2026-11-17 13:00:00") do
    assert {:ok, %{recorded: 1}} = receive!(ctx, message(id, from, text, at))
    assert :ok = process!(ctx)
    assert states(ctx) == ["processed"]
  end

  defp refusals(ctx, recipient_id),
    do: Enum.sort(sql!(ctx.scope, @refusals, [recipient_id]))

  defp consents(ctx, recipient_id), do: sql!(ctx.scope, @consents, [recipient_id])

  defp consent!(ctx, recipient_id, channel) do
    attrs = %{
      recipient_id: recipient_id,
      brand_subtenant_id: nil,
      channel: channel,
      status: "active",
      consent_kind: "explicit_opt_in",
      recipient_type: "individual",
      source: "access",
      sequence: 1,
      occurred_at: ~U[2026-11-01 10:00:00Z],
      text_version_digest: :crypto.hash(:sha256, "consent text v1"),
      evidence: %{"ip" => "203.0.113.9"},
      iys_transaction_ref: nil,
      source_event_ref: "evt_" <> TenantFixture.random()
    }

    {:ok, :recorded} = Relay.Preferences.record_consent(ctx.scope, attrs)
  end

  defp opt_in!(ctx, recipient_id, channel) do
    params = [Relay.Id.generate(), recipient_id, channel]
    assert [["set"]] = sql!(ctx.scope, @preference, params)
  end

  defp deliveries(ctx, external_id) do
    body = %{"workflow" => "newsletter", "to" => [external_id], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    Map.new(F.body(F.request(:get, path, ctx.token), 200)["data"], &{&1["channel"], &1})
  end

  describe "PC-37 a refusal keyword" do
    test "PC-37, PC-38, INV-18: RET is a refusal notice on SMS, applied at once, announced and answered once",
         ctx do
      {_external_id, recipient_id} = subscriber!(ctx, @phone, %{"locale" => "tr"})

      assert {:error, :bad_signature} = receive!(ctx, message(1, @phone, "ret"), "token-2")
      take!(ctx, 1, @phone, " Ret. ")

      assert refusals(ctx, recipient_id) == [["sms", "sms_keyword", "all_marketing"]]
      assert consents(ctx, recipient_id) == [["sms", "revoked", "relay", "sms_keyword"]]
      assert [[_refusal_id]] = F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id")

      assert [opted_out] = OutboxEvents.data(ctx.scope, "sms.opted_out")
      assert opted_out["provider_account_id"] == Relay.ExternalId.encode("pva", ctx.account_id)
      assert opted_out["rule_id"] == "consent.revoked"
      assert "sub_" <> _id = opted_out["recipient_id"]
      assert [%{"channel" => "sms"}] = OutboxEvents.data(ctx.scope, "consent.revoked")

      assert_received {:sent, "/v2/send.json", sent}
      assert [%{"dest" => "905551112233", "msg" => text}] = sent["messages"]
      assert text == Relay.Compliance.sms_reply(:refused, "tr", nil)
      assert sent["source_addr"] == @number
      assert "kw-" <> _receipt = sent["custom_id"]
      assert sent["is_commercial"] == false

      assert {:ok, %{recorded: 0, duplicates: 1}} = receive!(ctx, message(1, @phone, " Ret. "))
      assert :ok = process!(ctx)
      refute_received {:sent, _path, _body}
      assert [_once] = refusals(ctx, recipient_id)
      assert [_once] = OutboxEvents.data(ctx.scope, "sms.opted_out")
    end

    test "PC-37: a message that is no keyword, or from a stranger, changes nothing and is answered by no one",
         ctx do
      {_external_id, recipient_id} = subscriber!(ctx, @phone)

      take!(ctx, 2, @phone, "ret demek istemedim")
      take!(ctx, 3, "+905559998877", "RET")

      assert refusals(ctx, recipient_id) == []
      assert consents(ctx, recipient_id) == []
      assert OutboxEvents.data(ctx.scope, "sms.opted_out") == []
      refute_received {:sent, _path, _body}
    end

    test "PC-37: HELP is answered and changes nothing", ctx do
      {_external_id, recipient_id} = subscriber!(ctx, @phone, %{"locale" => "en"})

      take!(ctx, 4, @phone, "help")

      assert_received {:sent, "/v2/send.json", %{"messages" => [%{"msg" => text}]}}
      assert text == Relay.Compliance.sms_reply(:help, "en", nil)
      assert refusals(ctx, recipient_id) == []
      assert consents(ctx, recipient_id) == []
    end

    test "PC-37: START is a new evidenced consent in Relay's copy after a refusal", ctx do
      {_external_id, recipient_id} = subscriber!(ctx, @phone, %{"locale" => "tr"})

      take!(ctx, 5, @phone, "DUR", "2026-11-17 13:00:00")
      take!(ctx, 6, @phone, "start", "2026-11-17 13:05:00")

      assert consents(ctx, recipient_id) == [
               ["sms", "revoked", "relay", "sms_keyword"],
               ["sms", "active", "relay", "sms_keyword"]
             ]

      assert {:ok, [%{"channel" => "sms", "status" => "active"}]} =
               Relay.Preferences.get_consents(ctx.scope, recipient_id)

      assert_received {:sent, "/v2/send.json", %{"messages" => [%{"msg" => refused}]}}
      assert_received {:sent, "/v2/send.json", %{"messages" => [%{"msg" => restarted}]}}
      assert refused == Relay.Compliance.sms_reply(:refused, "tr", nil)
      assert restarted == Relay.Compliance.sms_reply(:restarted, "tr", nil)
    end
  end

  describe "PC-39 the scope of a revocation" do
    test "PC-39, PC-40: STOP from a number of the United States revokes the brand's SMS and voice",
         ctx do
      F.category!(ctx.token, "news", "marketing")

      F.workflow!(ctx.scope, ctx.token, "newsletter",
        category: "news",
        message_class: "marketing",
        channels: ["sms", "voice"]
      )

      fields = %{"timezone" => "America/New_York", "locale" => "en"}
      {external_id, recipient_id} = subscriber!(ctx, @american, fields)

      for channel <- ["sms", "voice"] do
        consent!(ctx, recipient_id, channel)
        opt_in!(ctx, recipient_id, channel)
      end

      before = deliveries(ctx, external_id)
      refute before["sms"]["rule_id"] == "consent.revoked"
      refute before["voice"]["rule_id"] == "consent.revoked"

      take!(ctx, 7, @american, "STOP")

      assert refusals(ctx, recipient_id) == [
               ["sms", "sms_keyword", "all_channel"],
               ["voice", "sms_keyword", "all_channel"]
             ]

      assert [_sms, _voice] = OutboxEvents.data(ctx.scope, "consent.revoked")
      assert [_only_sms] = OutboxEvents.data(ctx.scope, "sms.opted_out")

      assert {:ok, current} = Relay.Preferences.get_consents(ctx.scope, recipient_id)

      assert Enum.sort(for c <- current, do: {c["channel"], c["status"]}) ==
               [{"sms", "revoked"}, {"voice", "revoked"}]

      later = deliveries(ctx, external_id)
      assert %{"status" => "skipped", "rule_id" => "consent.revoked"} = later["sms"]
      assert %{"status" => "skipped", "rule_id" => "consent.revoked"} = later["voice"]

      assert_received {:sent, "/v2/send.json", %{"messages" => [%{"msg" => text}]}}
      assert text == Relay.Compliance.sms_reply(:refused, "en", nil)
    end
  end
end
