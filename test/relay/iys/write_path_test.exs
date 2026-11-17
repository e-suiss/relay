defmodule Relay.Iys.WritePathTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.IysFake, as: Fake
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @brand 9001
  @phone "+905321112233"
  @email "ayse@example.com"

  setup do
    calendar = {Datasets.installation_scope(), "business_calendar"}
    Datasets.Cache.invalidate(Datasets.Cache, calendar)
    on_exit(fn -> Datasets.Cache.invalidate(Datasets.Cache, calendar) end)
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    start_supervised!({Fake, []})
    :ok = FakeAccess.install!()

    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    sub = "pairwise-" <> FakeAccess.random()
    subscriber = %{"external_id" => sub, "phone" => @phone, "email" => @email}
    F.body(F.request(:post, "/v1/subscribers", token, subscriber), 201)
    {:ok, recipient_id} = Relay.Subscribers.locate(scope, sub)

    %{
      tenant: tenant,
      scope: scope,
      token: token,
      sub: sub,
      recipient_id: recipient_id,
      access_tenant: tenant.attrs.access_tenant_id,
      credential: credential!(scope)
    }
  end

  defp credential!(scope) do
    var = "RELAY_TEST_IYS_" <> String.upcase(TenantFixture.random())
    System.put_env(var, "iys-password")
    on_exit(fn -> System.delete_env(var) end)
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    {:ok, ref} = Relay.Secrets.register_ref(scope, :iys_credential, "${#{var}}", 1, digest, actor)
    ref.id
  end

  defp configure!(ctx, changes \\ %{}) do
    config =
      Map.merge(
        %{
          "mode" => "own",
          "api" => "sandbox",
          "iys_code" => 600_001,
          "integrator_code" => nil,
          "username" => "iys-user",
          "credential_ref_id" => Relay.Id.to_string(ctx.credential)
        },
        changes
      )

    brands = [%{"brand_code" => @brand, "name" => "Marka", "subtenant_id" => nil}]

    {:ok, {result, _version}} =
      Relay.Iys.in_scope(ctx.scope, fn _status ->
        Relay.Iys.put_config(config, brands, nil, TenantFixture.digest(), TenantFixture.actor())
      end)

    result
  end

  defp movement(ctx, changes \\ %{}) do
    Map.merge(
      %{
        channel: "sms",
        status: :approval,
        address: @phone,
        source: "web",
        occurred_at: DateTime.add(DateTime.utc_now(), -30, :second),
        origin: :access,
        recipient_type: "individual",
        recipient_id: ctx.recipient_id,
        brand_subtenant_id: nil
      },
      changes
    )
  end

  defp uploads(ctx, state \\ nil) do
    {:ok, rows} = Relay.Iys.list_uploads(ctx.scope, state, nil, 50)
    Enum.reverse(rows)
  end

  defp run(ctx, upload), do: Relay.Iys.run_upload(ctx.scope, upload["id"])

  defp count(operation) do
    Enum.count(Fake.calls(), fn {name, _status} -> name == operation end)
  end

  defp consent_rows(ctx) do
    {:ok, rows} =
      Relay.Repo.in_scope(ctx.scope, fn _status ->
        Relay.Repo.scoped_query!(
          """
          SELECT status, source, writer, iys_transaction_ref IS NOT NULL
          FROM relay.consents WHERE recipient_id = $1 ORDER BY created_at, id
          """,
          [ctx.recipient_id]
        ).rows
      end)

    rows
  end

  defp current(ctx) do
    path = "/v1/subscribers/#{ctx.sub}/consents"
    F.body(F.request(:get, path, ctx.token), 200)["data"]
  end

  defp deliver!(ctx, attrs) do
    data =
      Map.merge(
        %{
          "sub" => ctx.sub,
          "access_tenant_id" => ctx.access_tenant,
          "channel" => "sms",
          "status" => "ACTIVE",
          "source" => "WEB",
          "occurred_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -30, :second)),
          "sequence" => 1,
          "consent_kind" => "explicit_opt_in",
          "recipient_type" => "individual",
          "text_version_digest" => String.duplicate("ab", 32),
          "evidence" => %{"ip" => "203.0.113.7", "device" => "relay-test-device"}
        },
        attrs
      )

    claims = FakeAccess.event("consent.updated", data, "evt_" <> FakeAccess.random())
    assert FakeAccess.deliver(claims).status == 202
    FakeAccess.drain!()
    :ok
  end

  describe "PC-30 the write path" do
    test "PC-30: an approval is sent, read back and only then confirmed", ctx do
      assert configure!(ctx) == :created
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))

      assert [%{"state" => "pending", "consent_status" => "ONAY"} = upload] = uploads(ctx)
      assert upload["source"] == "HS_WEB"
      assert upload["consent_type"] == "MESAJ"
      assert is_binary(upload["address_ct"])
      refute upload["address_ct"] =~ @phone
      assert %DateTime{} = upload["deadline_at"]
      assert Fake.calls() == []

      assert run(ctx, upload) == :done

      assert [%{"state" => "confirmed", "address_ct" => nil} = confirmed] = uploads(ctx)
      assert confirmed["transaction_ref"] =~ ~r/\A[0-9a-f]{64}\z/
      assert %DateTime{} = confirmed["registered_at"]
      assert %DateTime{} = confirmed["settled_at"]
      assert Fake.calls() == [token: 200, add: 200, status: 200]
      assert [%{"status" => "ONAY", "source" => "HS_WEB"}] = Map.values(Fake.consents())

      assert run(ctx, upload) == :done
      assert count(:add) == 1
    end

    test "PC-30: a 200 is not a confirmation; the upload waits for a read-back that agrees",
         ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)

      :ok = Fake.fail_next(:status, 503, "H192")
      assert {:snooze, _seconds} = run(ctx, upload)

      assert [%{"state" => "uploaded", "settled_at" => nil} = waiting] = uploads(ctx)
      assert waiting["transaction_ref"] =~ ~r/\A[0-9a-f]{64}\z/
      assert is_binary(waiting["address_ct"])

      assert run(ctx, upload) == :done
      assert [%{"state" => "confirmed"}] = uploads(ctx)
      assert count(:add) == 1
      assert count(:status) == 2
    end

    test "PC-30: a status that keeps disagreeing fails the upload for the operator", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)

      for _attempt <- 1..2 do
        :ok = Fake.fail_next(:status, 204, nil)
        assert {:snooze, _seconds} = run(ctx, upload)
        assert [%{"state" => "pending", "error_code" => "readback_mismatch"}] = uploads(ctx)
      end

      :ok = Fake.fail_next(:status, 204, nil)
      assert run(ctx, upload) == :done

      assert [%{"state" => "failed", "error_code" => "readback_mismatch"}] = uploads(ctx)
      events = OutboxEvents.data(ctx.scope, "iys.upload_failed")
      assert [%{"error_code" => "readback_mismatch"}] = events
    end

    test "PC-30: a refusal İYS gives for good is kept for the operator and announced", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)

      :ok = Fake.fail_next(:add, 422, "H121")
      assert run(ctx, upload) == :done

      assert [%{"state" => "failed", "error_code" => "H121"} = failed] = uploads(ctx, "failed")
      assert failed["trace_ref"] =~ ~r/\A[0-9a-f]{32}\z/
      assert is_binary(failed["address_ct"])

      assert [event] = OutboxEvents.data(ctx.scope, "iys.upload_failed")
      assert event["upload_id"] == Relay.ExternalId.encode("iyu", upload["id"])
      assert %{"channel" => "sms", "status" => "approval", "brand_code" => @brand} = event
      refute Jason.encode!(event) =~ @phone
    end

    test "PC-34: a movement that fails the local checks is never sent", ctx do
      configure!(ctx)
      unknown = movement(ctx, %{source: "carrier_pigeon"})
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, unknown)
      [upload] = uploads(ctx)

      assert run(ctx, upload) == :done
      assert [%{"state" => "failed", "error_code" => "invalid_source"}] = uploads(ctx)
      assert count(:add) == 0
    end

    test "PC-30, PC-31: an approval older than three business days expires", ctx do
      configure!(ctx)
      old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx, %{occurred_at: old}))
      [upload] = uploads(ctx)
      assert DateTime.compare(upload["deadline_at"], DateTime.utc_now()) == :lt

      assert run(ctx, upload) == :done

      assert [%{"state" => "expired", "error_code" => "deadline_passed"}] = uploads(ctx)
      assert [%{"channel" => "sms"} = event] = OutboxEvents.data(ctx.scope, "iys.consent_expired")
      assert event["upload_id"] == Relay.ExternalId.encode("iyu", upload["id"])
      assert Fake.calls() == []
    end

    test "PC-30, PC-31: the sweep expires what is overdue and İYS's own H467 expires too", ctx do
      configure!(ctx)
      old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx, %{occurred_at: old}))

      assert {:ok, %{expired: 1, queued: 0}} = Relay.Iys.sweep(ctx.scope, DateTime.utc_now())
      assert [%{"state" => "expired"}] = uploads(ctx)

      other = movement(ctx, %{address: "+905321112244"})
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, other)
      upload = List.last(uploads(ctx))
      :ok = Fake.fail_next(:add, 422, "H467")

      assert run(ctx, upload) == :done
      assert %{"state" => "expired", "error_code" => "H467"} = List.last(uploads(ctx))
      assert length(OutboxEvents.data(ctx.scope, "iys.consent_expired")) == 2
    end

    test "PC-30: movements of one recipient, brand and type go one at a time, in order", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      later = movement(ctx, %{occurred_at: DateTime.add(DateTime.utc_now(), -5, :second)})
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, later)
      [first, second] = uploads(ctx)

      assert {:snooze, 5} = run(ctx, second)
      assert Fake.calls() == []

      assert run(ctx, first) == :done
      assert {:snooze, 5} = run(ctx, second)
      assert count(:add) == 1
    end

    test "PC-30: a refusal goes first and withdraws an approval that was not sent", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      refusal = movement(ctx, %{status: :rejection, source: "sms_keyword", origin: :refusal})
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, refusal)
      assert {:ok, :duplicate} = Relay.Iys.write(ctx.scope, refusal)

      assert [approval, rejection] = uploads(ctx)
      assert %{"state" => "skipped", "error_code" => "superseded"} = approval
      assert %{"state" => "pending", "consent_status" => "RET", "deadline_at" => nil} = rejection
      assert rejection["source"] == "HS_MESAJ"

      assert run(ctx, rejection) == :done
      assert %{"state" => "skipped", "error_code" => "H175"} = List.last(uploads(ctx))
      assert Fake.consents() == %{}
    end

    test "PC-30: a refusal of a recorded consent is written as RET and confirmed", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [approval] = uploads(ctx)
      assert run(ctx, approval) == :done

      Process.sleep(2_100)
      refusal = %{channel: "sms", address: @phone, source: "sms_keyword", brand: @brand}
      assert {:ok, :queued} = Relay.Iys.write_refusal(ctx.scope, refusal)
      rejection = List.last(uploads(ctx))
      assert rejection["origin"] == "refusal"
      assert rejection["recipient_id"] == nil

      assert run(ctx, rejection) == :done
      assert %{"state" => "confirmed", "address_ct" => nil} = List.last(uploads(ctx))
      assert [%{"status" => "RET", "source" => "HS_MESAJ"}] = Map.values(Fake.consents())
    end
  end

  describe "E-20 PC-28 PC-27 scope" do
    test "PC-27: a channel İYS does not know and a scope without a configuration write nothing",
         ctx do
      assert {:ok, :not_configured} = Relay.Iys.write(ctx.scope, movement(ctx))
      configure!(ctx)

      for channel <- ~w(push whatsapp in_app) do
        outside = movement(ctx, %{channel: channel})
        assert {:ok, :out_of_scope} = Relay.Iys.write(ctx.scope, outside)
      end

      assert uploads(ctx) == []
      assert Fake.calls() == []
    end

    test "PC-29: a movement of a brand that is not configured fails for the operator", ctx do
      configure!(ctx)
      refusal = %{channel: "email", address: @email, source: "one_click", brand: 4242}

      assert {:ok, :brand_not_mapped} = Relay.Iys.write_refusal(ctx.scope, refusal)
      assert [%{"state" => "failed", "error_code" => "brand_not_mapped"}] = uploads(ctx)
      assert [%{"brand_code" => nil}] = OutboxEvents.data(ctx.scope, "iys.upload_failed")
    end

    test "E-20, PC-28: the configuration is one per environment and its brands are archived, not deleted",
         ctx do
      assert configure!(ctx) == :created
      assert configure!(ctx, %{"username" => "other"}) == :updated

      {:ok, %{config: config, brands: [brand]}} = Relay.Iys.get_config(ctx.scope)
      assert %{"username" => "other", "version" => 2, "mode" => "own"} = config
      assert %{"brand_code" => @brand, "message_access" => "write"} = brand
      assert %DateTime{} = brand["authorised_at"]

      {:ok, {:version_conflict, 2}} =
        Relay.Iys.in_scope(ctx.scope, fn _status ->
          Relay.Iys.put_config(config(ctx), [], 1, TenantFixture.digest(), TenantFixture.actor())
        end)

      {:ok, {:updated, 3}} =
        Relay.Iys.in_scope(ctx.scope, fn _status ->
          Relay.Iys.put_config(config(ctx), [], 2, TenantFixture.digest(), TenantFixture.actor())
        end)

      assert {:ok, %{brands: []}} = Relay.Iys.get_config(ctx.scope)

      {:ok, rows} =
        Relay.Repo.in_scope(ctx.scope, fn _status ->
          Relay.Repo.scoped_query!("SELECT state FROM relay.iys_brands", []).rows
        end)

      assert rows == [["archived"]]
    end

    test "PC-29: a test environment may only use the sandbox and a credential must be an İYS one",
         ctx do
      test_ctx = %{ctx | scope: ctx.tenant.test, credential: credential!(ctx.tenant.test)}
      assert configure!(test_ctx, %{"api" => "production"}) == :sandbox_required
      assert configure!(test_ctx) == :created

      stranger = Relay.Id.to_string(Relay.Id.generate())
      assert configure!(ctx, %{"credential_ref_id" => stranger}) == :secret_not_found
    end
  end

  defp config(ctx) do
    %{
      "mode" => "own",
      "api" => "sandbox",
      "iys_code" => 600_001,
      "integrator_code" => nil,
      "username" => "other",
      "credential_ref_id" => Relay.Id.to_string(ctx.credential)
    }
  end

  describe "PC-29 E-22 integrator mode" do
    test "PC-29, E-22: nothing is written until the integrator's write access was read", ctx do
      integrator = %{"mode" => "integrator", "integrator_code" => 700_001}
      assert configure!(ctx, integrator) == :created

      {:ok, %{brands: [brand]}} = Relay.Iys.get_config(ctx.scope)
      assert %{"message_access" => "unknown", "authorised_at" => nil} = brand

      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)
      assert {:snooze, 1800} = run(ctx, upload)
      assert [%{"state" => "pending", "error_code" => "not_authorised"}] = uploads(ctx)
      assert count(:add) == 0

      access = %{"MESAJ" => "read", "ARAMA" => "write", "EPOSTA" => "write"}
      :ok = Fake.put(:authorisations, %{@brand => access})
      now = DateTime.utc_now()
      assert {:ok, %{authorisations: :observed}} = Relay.Iys.refresh(ctx.scope, now)
      {:ok, %{brands: [read_only]}} = Relay.Iys.get_config(ctx.scope)
      assert %{"message_access" => "read", "call_access" => "write"} = read_only
      assert {:snooze, 1800} = run(ctx, upload)
      assert count(:add) == 0

      :ok = Fake.put(:authorisations, %{@brand => %{access | "MESAJ" => "write"}})
      assert {:ok, _read} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())
      assert run(ctx, upload) == :done
      assert [%{"state" => "confirmed"}] = uploads(ctx)
    end

    test "PC-29: an authorisation that was not read again in time stops the writes", ctx do
      integrator = %{"mode" => "integrator", "integrator_code" => 700_001}
      configure!(ctx, integrator)
      long_ago = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      assert {:ok, %{authorisations: :observed}} = Relay.Iys.refresh(ctx.scope, long_ago)

      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)
      assert {:snooze, 1800} = run(ctx, upload)
      assert [%{"error_code" => "authorisation_stale"}] = uploads(ctx)

      :ok = Fake.put(:authorisations, %{})
      assert {:ok, _read} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())
      {:ok, %{brands: [brand]}} = Relay.Iys.get_config(ctx.scope)
      assert %{"message_access" => "none", "email_access" => "none"} = brand
    end
  end

  describe "PC-34 operation" do
    test "PC-34: a connection İYS refuses is marked and not asked again for a while", ctx do
      configure!(ctx)
      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)

      :ok = Fake.fail_next(:add, 403, "H586")
      assert {:snooze, 1800} = run(ctx, upload)

      {:ok, %{config: config}} = Relay.Iys.get_config(ctx.scope)
      assert %{"blocked_code" => "H586", "blocked_at" => %DateTime{}} = config
      assert [%{"state" => "pending", "error_code" => "H586"}] = uploads(ctx)

      before = length(Fake.calls())
      assert {:snooze, 1800} = run(ctx, upload)
      assert length(Fake.calls()) == before

      assert {:ok, _read} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())
      {:ok, %{config: cleared}} = Relay.Iys.get_config(ctx.scope)
      assert cleared["blocked_code"] == nil
      assert run(ctx, upload) == :done
    end

    test "PC-34: the consent quota is watched and the tenant is warned once per change", ctx do
      configure!(ctx)
      subscription = Fake.get(:subscription)

      assert {:ok, %{quota: "ok"}} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())
      assert OutboxEvents.data(ctx.scope, "iys.quota_warning") == []

      :ok = Fake.put(:subscription, %{subscription | "usedConsentLimit" => 800})
      assert {:ok, %{quota: "warning"}} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())
      assert {:ok, %{quota: "warning"}} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())

      :ok = Fake.put(:subscription, %{subscription | "usedConsentLimit" => 1000})
      assert {:ok, %{quota: "full"}} = Relay.Iys.refresh(ctx.scope, DateTime.utc_now())

      assert [%{"state" => "warning", "used_consent_limit" => 800}, %{"state" => "full"}] =
               OutboxEvents.data(ctx.scope, "iys.quota_warning")

      {:ok, %{config: config}} = Relay.Iys.get_config(ctx.scope)
      assert %{"quota_state" => "full", "consent_limit" => 1000} = config

      assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement(ctx))
      [upload] = uploads(ctx)
      assert run(ctx, upload) == :done
      assert [%{"state" => "failed", "error_code" => "H525"}] = uploads(ctx)
    end
  end

  describe "E-21 Access consents" do
    test "E-21, PC-28, PC-30: an Access approval is pending_iys until Relay wrote it to İYS",
         ctx do
      configure!(ctx)
      :ok = deliver!(ctx, %{})

      assert consent_rows(ctx) == [["pending_iys", "web", "access", false]]
      assert [%{"status" => "pending_iys"}] = current(ctx)
      assert [%{"state" => "pending", "origin" => "access"} = upload] = uploads(ctx)
      assert upload["recipient_id"] == ctx.recipient_id
      assert is_binary(upload["consent_id"])
      assert Fake.calls() == []

      assert run(ctx, upload) == :done

      assert consent_rows(ctx) == [
               ["pending_iys", "web", "access", false],
               ["active", "iys", "relay", true]
             ]

      assert [%{"status" => "active", "source" => "iys"}] = current(ctx)
      assert [%{"recipient" => @phone, "status" => "ONAY"}] = Map.values(Fake.consents())
    end

    test "E-21, PC-30: a revocation applies in Relay at once and follows to İYS as RET", ctx do
      configure!(ctx)
      :ok = deliver!(ctx, %{})
      [approval] = uploads(ctx)
      assert run(ctx, approval) == :done

      Process.sleep(2_100)
      :ok = deliver!(ctx, %{"status" => "REVOKED", "sequence" => 2})

      assert [%{"status" => "revoked"}] = current(ctx)
      rejection = List.last(uploads(ctx))
      assert %{"consent_status" => "RET", "state" => "pending"} = rejection

      assert run(ctx, rejection) == :done
      assert ["revoked", "iys", "relay", true] = List.last(consent_rows(ctx))
      assert [%{"status" => "RET"}] = Map.values(Fake.consents())
    end

    test "E-21, PC-30: an approval İYS never recorded expires in the consent copy", ctx do
      configure!(ctx)
      old = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -10 * 86_400, :second))
      :ok = deliver!(ctx, %{"occurred_at" => old})

      [upload] = uploads(ctx)
      assert run(ctx, upload) == :done

      assert [%{"status" => "expired", "source" => "iys"}] = current(ctx)
      assert List.last(consent_rows(ctx)) == ["expired", "iys", "relay", false]
    end

    test "E-21, PC-27: a consent of a channel outside İYS stays as Access recorded it", ctx do
      configure!(ctx)
      :ok = deliver!(ctx, %{"channel" => "whatsapp"})

      assert consent_rows(ctx) == [["active", "web", "access", false]]
      assert uploads(ctx) == []
    end

    test "E-21, PC-28: a repeated event queues its consent once", ctx do
      configure!(ctx)
      :ok = deliver!(ctx, %{})
      :ok = deliver!(ctx, %{})

      assert [%{"state" => "pending"}] = uploads(ctx)
      assert length(consent_rows(ctx)) == 1
    end
  end
end
