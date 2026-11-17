defmodule Relay.Iys.ReadPathTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.Policy.Engine
  alias Relay.Policy.Fixture
  alias Relay.Policy.IysGate
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.IysFake, as: Fake
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @brand 9001
  @phone "+905321112233"
  @email "ayse@example.com"
  @hour 3_600

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
      credential: credential!(scope),
      t0: DateTime.utc_now()
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

  defp citizen!(status, changes \\ %{}) do
    consent = Map.merge(%{"recipient" => @phone, "type" => "MESAJ", "status" => status}, changes)
    :ok = Fake.citizen(@brand, consent)
  end

  defp after_blind_spot, do: Fake.advance(@hour + 1)

  defp at(ctx, seconds), do: DateTime.add(ctx.t0, seconds, :second)

  defp sync!(ctx, seconds \\ 0) do
    assert {:ok, [report]} = Relay.Iys.sync(ctx.scope, at(ctx, seconds))
    report
  end

  defp state(ctx, seconds \\ 0) do
    assert {:ok, [brand]} = Relay.Iys.sync_status(ctx.scope, at(ctx, seconds))
    brand
  end

  defp gate(ctx, channel, address) do
    name = Atom.to_string(channel)

    {:ok, [{_key_id, digest} | _older]} =
      Relay.Subscribers.address_digests(ctx.scope, name, address)

    {:ok, status} =
      Relay.Repo.in_scope(ctx.scope, fn _status ->
        IysGate.status(ctx.scope, nil, channel, digest)
      end)

    status
  end

  defp decide(ctx, status, seconds, changes \\ []) do
    base = [
      channel: :sms,
      notification: [message_class: :marketing],
      preferences: [category_channel: :opt_in],
      consent: %{state: :active, ref: "c1"},
      iys: aged(status, at(ctx, seconds)),
      iys_stale_after_ms: IysGate.stale_stop_ms()
    ]

    Engine.evaluate(Fixture.snapshot(base ++ changes))
  end

  defp aged({:cached, state, synced}, %DateTime{} = now) when is_integer(synced) do
    age = DateTime.to_unix(now, :millisecond) - synced
    {:cached, state, DateTime.to_unix(Fixture.now(), :millisecond) - age}
  end

  defp aged(status, _now), do: status

  defp merchant, do: [compliance: Fixture.compliance(recipient_type: :merchant)]

  defp sql!(ctx, sql, params \\ []) do
    {:ok, rows} =
      Relay.Repo.in_scope(ctx.scope, fn _status -> Relay.Repo.scoped_query!(sql, params).rows end)

    rows
  end

  defp permissions(ctx) do
    sql!(ctx, """
    SELECT consent_status, origin, refusal_state, pulled_at IS NOT NULL, superseded_at IS NULL
    FROM relay.iys_permissions ORDER BY created_at, id
    """)
  end

  defp consent_rows(ctx) do
    sql = """
    SELECT status, source, writer FROM relay.consents
    WHERE recipient_id = $1 ORDER BY created_at, id
    """

    sql!(ctx, sql, [ctx.recipient_id])
  end

  defp uploads(ctx) do
    {:ok, rows} = Relay.Iys.list_uploads(ctx.scope, nil, nil, 50)
    Enum.reverse(rows)
  end

  defp movement do
    %{
      channel: "sms",
      status: :approval,
      address: @phone,
      source: "web",
      occurred_at: DateTime.add(DateTime.utc_now(), -30, :second),
      origin: :access,
      recipient_type: "individual",
      recipient_id: nil,
      brand_subtenant_id: nil
    }
  end

  defp approve!(ctx) do
    assert {:ok, :queued} = Relay.Iys.write(ctx.scope, movement())
    upload = List.last(uploads(ctx))
    assert Relay.Iys.run_upload(ctx.scope, upload["id"]) == :done
    upload
  end

  defp count(operation), do: Enum.count(Fake.calls(), &(elem(&1, 0) == operation))

  describe "PC-32 the pull and the permission cache" do
    test "PC-32: the pull reads İYS's movements after its cursor and the gate answers from the cache alone",
         ctx do
      configure!(ctx)
      assert gate(ctx, :sms, @phone) == {:cached, :none, nil}

      citizen!("ONAY")
      after_blind_spot()
      assert %{pull: :ok, applied: 1, refusals: 0, brand_code: @brand} = sync!(ctx)

      assert {:cached, :approved, synced} = gate(ctx, :sms, @phone)
      assert synced == DateTime.to_unix(ctx.t0, :millisecond)
      assert gate(ctx, :email, @email) == {:cached, :none, synced}
      assert [["ONAY", "pull", nil, true, true]] = permissions(ctx)

      calls = count(:changes)
      assert %{pull: :not_due} = sync!(ctx, 5 * 60)
      assert count(:changes) == calls

      citizen!("RET")
      after_blind_spot()
      assert %{pull: :ok, applied: 1} = sync!(ctx, 16 * 60)
      assert {:cached, :rejected, _synced} = gate(ctx, :sms, @phone)

      assert [["ONAY", "pull", nil, true, false], ["RET", "pull", _refusal, true, true]] =
               permissions(ctx)

      assert %{pull: :ok, applied: 0} = sync!(ctx, 32 * 60)
      assert count(:status) == 0
    end

    test "PC-32: İYS's last hour is a blind spot the operator is shown", ctx do
      configure!(ctx)
      citizen!("ONAY")

      assert %{pull: :ok, applied: 0} = sync!(ctx)
      assert {:cached, :none, _synced} = gate(ctx, :sms, @phone)

      brand = state(ctx, 60)
      assert brand.blind_spot_seconds == @hour
      assert brand.cursor_age_seconds == 60
      assert DateTime.compare(brand.covered_until, at(ctx, -@hour)) == :eq
      assert brand.stale_state == "fresh"

      after_blind_spot()
      assert %{pull: :ok, applied: 1} = sync!(ctx, 16 * 60)
      assert {:cached, :approved, _synced} = gate(ctx, :sms, @phone)
    end

    test "PC-32: a pull that fails keeps the last synchronisation and its cursor and is tried again",
         ctx do
      configure!(ctx)
      citizen!("ONAY")
      after_blind_spot()
      sync!(ctx)

      :ok = Fake.fail_next(:changes, 503, "H192")
      assert %{pull: :failed} = sync!(ctx, 16 * 60)

      brand = state(ctx, 16 * 60)
      assert brand.last_error_code == "H192"
      assert DateTime.compare(brand.last_pull_at, ctx.t0) == :eq
      assert {:cached, :approved, synced} = gate(ctx, :sms, @phone)
      assert synced == DateTime.to_unix(ctx.t0, :millisecond)

      assert %{pull: :ok} = sync!(ctx, 32 * 60)
      assert state(ctx, 32 * 60).last_error_code == nil
    end

    test "PC-32, INV-43: after seven days without a pull a full synchronisation runs and an approval held before it counts only once it was verified",
         ctx do
      configure!(ctx)
      citizen!("ONAY")
      after_blind_spot()
      sync!(ctx)
      assert {:cached, :approved, synced} = gate(ctx, :sms, @phone)
      assert is_integer(synced)

      Fake.advance(8 * 86_400)
      gap = 8 * 86_400
      assert %{pull: :ok, applied: 0, verified: 0} = sync!(ctx, gap)

      brand = state(ctx, gap)
      assert DateTime.compare(brand.full_sync_floor_at, at(ctx, gap)) == :eq
      assert DateTime.compare(brand.last_full_sync_at, at(ctx, gap)) == :eq
      refute brand.full_sync_running

      assert gate(ctx, :sms, @phone) == {:cached, :approved, nil}
      assert {:skip, :iys_stale, "iys.stale", _detail} = decide(ctx, gate(ctx, :sms, @phone), gap)

      assert %{verified: 1} = sync!(ctx, gap + 16 * 60)
      assert count(:status) == 1
      assert {:cached, :approved, verified} = gate(ctx, :sms, @phone)
      assert verified == DateTime.to_unix(at(ctx, gap + 16 * 60), :millisecond)
      assert {:send, _detail} = decide(ctx, gate(ctx, :sms, @phone), gap + 16 * 60)
    end

    test "PC-32: a rejection made at İYS during the gap is found by the verification and applied",
         ctx do
      configure!(ctx)
      citizen!("ONAY")
      after_blind_spot()
      sync!(ctx)

      citizen!("RET")
      Fake.advance(8 * 86_400)
      gap = 8 * 86_400
      assert %{pull: :ok, applied: 0} = sync!(ctx, gap)
      assert %{verified: 1, refusals: 1} = sync!(ctx, gap + 16 * 60)

      assert {:cached, :rejected, _synced} = gate(ctx, :sms, @phone)
      assert [["revoked", "iys", "relay"]] = consent_rows(ctx)
    end

    test "PC-32: the single verification is the one live question and writes its answer to the cache",
         ctx do
      assert {:ok, :not_configured} =
               Relay.Iys.verify(ctx.scope, %{channel: "sms", address: @phone})

      configure!(ctx)
      assert {:ok, :out_of_scope} = Relay.Iys.verify(ctx.scope, %{channel: "push", address: "x"})
      assert {:ok, :none} = Relay.Iys.verify(ctx.scope, %{channel: "sms", address: @phone})

      citizen!("ONAY")
      assert {:ok, :approved} = Relay.Iys.verify(ctx.scope, %{channel: "sms", address: @phone})
      assert count(:status) == 2
      assert [["ONAY", "verify", nil, true, true]] = permissions(ctx)

      before = count(:status)
      assert {:cached, :approved, nil} = gate(ctx, :sms, @phone)
      assert count(:status) == before
    end
  end

  describe "PC-38 PC-28 rejections" do
    test "PC-32, PC-38: a rejection pulled from İYS is applied in Relay as a refusal of source iys and is not written back",
         ctx do
      configure!(ctx)
      citizen!("ONAY")
      Fake.advance(5)
      citizen!("RET")
      after_blind_spot()

      assert %{pull: :ok, applied: 2, refusals: 1} = sync!(ctx)
      assert {:cached, :rejected, _synced} = gate(ctx, :sms, @phone)
      assert [["revoked", "iys", "relay"]] = consent_rows(ctx)

      assert [%{"source" => "iys", "channel" => "sms", "scope" => "all_marketing"}] =
               OutboxEvents.data(ctx.scope, "consent.revoked")

      assert uploads(ctx) == []
      assert count(:add) == 0

      assert %{refusals: 0} = sync!(ctx, 16 * 60)
      assert length(OutboxEvents.data(ctx.scope, "consent.revoked")) == 1
      assert [_approval, ["RET", "pull", "applied", true, true]] = permissions(ctx)
    end

    test "PC-32: a rejection of an address no recipient has stays in the cache and stops a later recipient",
         ctx do
      configure!(ctx)
      other = "+905339998877"
      citizen!("ONAY", %{"recipient" => other})
      Fake.advance(5)
      citizen!("RET", %{"recipient" => other})
      after_blind_spot()

      assert %{applied: 2, refusals: 0} = sync!(ctx)
      assert [_approval, ["RET", "pull", "unmatched", true, true]] = permissions(ctx)
      assert {:cached, :rejected, _synced} = gate(ctx, :sms, other)
      assert consent_rows(ctx) == []
    end

    test "PC-38, PC-28, §7.11: a refusal applied in Relay reaches İYS as a rejection through the sink, waits while İYS is unreachable, and the pull confirms it",
         ctx do
      assert Relay.Compliance.RefusalSink.sink() == Relay.Iys.Live
      configure!(ctx)
      approve!(ctx)
      assert {:cached, :approved, nil} = gate(ctx, :sms, @phone)
      assert [["ONAY", "upload", nil, false, true]] = permissions(ctx)

      Process.sleep(2_100)

      refusal = %{
        recipient_id: ctx.recipient_id,
        channel: "sms",
        source: "sms_keyword",
        ref: "sms:" <> TenantFixture.random()
      }

      assert {:ok, %{result: :applied, refusal_id: refusal_id}} =
               Relay.Compliance.refuse(ctx.scope, refusal)

      assert [["revoked", "sms_keyword", "relay"]] = consent_rows(ctx)
      assert :ok = Relay.Compliance.Refusals.forward(ctx.scope, refusal_id)

      rejection = List.last(uploads(ctx))
      assert %{"consent_status" => "RET", "origin" => "refusal", "state" => "pending"} = rejection

      :ok = Fake.fail_next(:add, 503, "H192")
      assert {:snooze, _seconds} = Relay.Iys.run_upload(ctx.scope, rejection["id"])
      assert [["revoked", "sms_keyword", "relay"]] = consent_rows(ctx)
      assert [%{"status" => "ONAY"}] = Map.values(Fake.consents())

      assert Relay.Iys.run_upload(ctx.scope, rejection["id"]) == :done
      assert [%{"status" => "RET", "source" => "HS_MESAJ"}] = Map.values(Fake.consents())
      assert {:cached, :rejected, nil} = gate(ctx, :sms, @phone)

      after_blind_spot()
      assert %{pull: :ok, refusals: 0} = sync!(ctx)

      assert [["ONAY", "upload", nil, false, false], ["RET", "upload", nil, true, true]] =
               permissions(ctx)

      assert length(uploads(ctx)) == 2
      assert length(OutboxEvents.data(ctx.scope, "consent.revoked")) == 1
      assert {:cached, :rejected, synced} = gate(ctx, :sms, @phone)
      assert is_integer(synced)
    end
  end

  describe "PC-33 INV-19 the gate" do
    test "PC-27, INV-19: a tenant in scope without İYS information is not configured", ctx do
      assert TenantFixture.region() == :tr
      assert gate(ctx, :sms, @phone) == :not_configured

      assert {:skip, :iys_not_configured, "iys.not_configured", _detail} =
               decide(ctx, gate(ctx, :sms, @phone), 0)
    end

    test "PC-33, INV-19, INV-43: a copy that never synchronised or is a day old stops marketing",
         ctx do
      configure!(ctx)
      never = gate(ctx, :sms, @phone)
      assert never == {:cached, :none, nil}
      assert {:skip, :iys_stale, "iys.stale", _detail} = decide(ctx, never, 0)

      citizen!("ONAY")
      after_blind_spot()
      sync!(ctx)
      approved = gate(ctx, :sms, @phone)

      assert {:send, _detail} = decide(ctx, approved, 23 * @hour)
      assert {:skip, :iys_stale, "iys.stale", detail} = decide(ctx, approved, 24 * @hour)
      assert %DateTime{} = detail.iys_synced_at

      assert {:skip, :iys_stale, "iys.stale", _detail} =
               decide(ctx, approved, 24 * @hour, merchant())
    end

    test "PC-21, PC-33: an approval counts only when İYS holds it; Relay's own active consent is not enough",
         ctx do
      configure!(ctx)
      sync!(ctx)
      none = gate(ctx, :sms, @phone)
      assert {:cached, :none, synced} = none
      assert is_integer(synced)

      assert {:skip, :consent_missing, "iys.approval_missing", _detail} = decide(ctx, none, 60)

      citizen!("ONAY")
      after_blind_spot()
      sync!(ctx, 16 * 60)
      assert {:send, _detail} = decide(ctx, gate(ctx, :sms, @phone), 17 * 60)
    end

    test "PC-24, INV-19: a merchant needs no approval and is stopped only by a rejection İYS holds",
         ctx do
      configure!(ctx)
      sync!(ctx)
      assert {:send, _detail} = decide(ctx, gate(ctx, :sms, @phone), 60, merchant())

      citizen!("ONAY", %{"recipientType" => "TACIR"})
      Fake.advance(5)
      citizen!("RET", %{"recipientType" => "TACIR"})
      after_blind_spot()
      sync!(ctx, 16 * 60)

      rejected = gate(ctx, :sms, @phone)
      assert {:cached, :rejected, _synced} = rejected

      assert {:skip, :consent_revoked, "iys.rejected", _detail} =
               decide(ctx, rejected, 17 * 60, merchant())

      assert {:skip, :consent_revoked, "iys.rejected", _detail} = decide(ctx, rejected, 17 * 60)
    end

    test "PC-33: a stale copy is announced to the tenant at the warning and at the stop age, once each",
         ctx do
      configure!(ctx)
      sync!(ctx)
      assert {:ok, 0} = Relay.Iys.stale_check(ctx.scope, at(ctx, 5 * @hour))
      assert {:ok, 1} = Relay.Iys.stale_check(ctx.scope, at(ctx, 7 * @hour))
      assert {:ok, 0} = Relay.Iys.stale_check(ctx.scope, at(ctx, 8 * @hour))
      assert state(ctx, 8 * @hour).stale_state == "warning"

      assert [%{"state" => "warning", "brand_code" => @brand} = warned] =
               OutboxEvents.data(ctx.scope, "iys.copy_stale")

      assert is_binary(warned["last_synced_at"])

      assert {:ok, 1} = Relay.Iys.stale_check(ctx.scope, at(ctx, 25 * @hour))

      assert [_warning, %{"state" => "stopped"}] =
               OutboxEvents.data(ctx.scope, "iys.copy_stale")

      overview = Relay.Iys.Store.overview(at(ctx, 25 * @hour))
      assert overview["stale_stopped"] >= 1
      assert :ok = Relay.Iys.SyncSweep.report(overview)

      sync!(ctx, 25 * @hour)
      assert {:ok, 1} = Relay.Iys.stale_check(ctx.scope, at(ctx, 25 * @hour + 60))
      assert state(ctx, 25 * @hour + 60).stale_state == "fresh"
      assert length(OutboxEvents.data(ctx.scope, "iys.copy_stale")) == 2
    end
  end

  describe "OP-42 E-22 reconciliation" do
    test "OP-42: the hourly reconciliation counts an upload no pull reported as drift and the verification repairs it",
         ctx do
      configure!(ctx)
      approve!(ctx)

      assert %{reconciled: true, verified: 0} = sync!(ctx)
      assert state(ctx).drift_count == 0
      assert %{reconciled: false} = sync!(ctx, 16 * 60)

      :ok = Fake.fail_next(:status, 503, "H192")
      assert %{reconciled: true, verified: 0} = sync!(ctx, 2 * @hour)
      assert state(ctx, 2 * @hour).drift_count == 1
      assert Relay.Iys.Store.overview(at(ctx, 2 * @hour))["drift"] >= 1

      assert %{reconciled: true, verified: 1} = sync!(ctx, 3 * @hour + 60)
      assert state(ctx, 3 * @hour + 60).drift_count == 0
      assert [["ONAY", "upload", nil, true, true]] = permissions(ctx)
    end

    test "E-22: the distinct addresses of a brand are counted and measured against the direct access threshold in integrator mode",
         ctx do
      configure!(ctx, %{"mode" => "integrator", "integrator_code" => 700_001})
      citizen!("ONAY")
      citizen!("ONAY", %{"recipient" => @email, "type" => "EPOSTA"})
      citizen!("ONAY", %{"recipient" => "+905339998877"})
      Fake.advance(5)
      citizen!("RET", %{"recipient" => "+905339998877"})
      after_blind_spot()

      assert %{pull: :ok, applied: 4, reconciled: true} = sync!(ctx)
      assert %{address_count: 3, address_state: "ok"} = state(ctx)

      integrator = %{"mode" => "integrator"}
      threshold = Relay.Limits.fetch!(["iys", "direct_access_threshold"])
      assert threshold == 250_000
      assert Relay.Iys.Sync.address_state(integrator, 199_999) == "ok"
      assert Relay.Iys.Sync.address_state(integrator, 200_000) == "warning"
      assert Relay.Iys.Sync.address_state(integrator, 249_999) == "warning"
      assert Relay.Iys.Sync.address_state(integrator, threshold) == "reached"
      assert Relay.Iys.Sync.address_state(%{"mode" => "own"}, threshold) == "ok"
    end
  end
end
