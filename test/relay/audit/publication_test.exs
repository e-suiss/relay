defmodule Relay.Audit.PublicationTest do
  use Relay.MaintenanceCase, async: false

  import Mox

  alias Relay.Audit.Checkpointer
  alias Relay.Audit.Checkpointer.Publisher.S3
  alias Relay.Audit.Checkpointer.Readback
  alias Relay.Audit.Checkpointer.Verifier
  alias Relay.Platform.Leadership.Store
  alias Relay.Platform.Maintenance.EscapeHatch
  alias RelayDev.ObjectStore

  setup :set_mox_global

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    store = ObjectStore.local(bucket: "relay-audit-test")
    :ok = ObjectStore.setup(store)
    %{store: store}
  end

  setup %{store: store} do
    {public, secret} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, "relay-test-checkpoint"))

    host = "p" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower) <> ".test"
    keys = Application.fetch_env!(:relay, :keys)
    audit = Application.get_env(:relay, Relay.Audit)
    Application.put_env(:relay, :keys, Relay.KeysMock)

    Application.put_env(:relay, Relay.Audit,
      log_host: host,
      checkpoint_key: "audit-checkpoint",
      publishers: [{"worm_store", S3, store}]
    )

    on_exit(fn ->
      Application.put_env(:relay, :keys, keys)
      Application.put_env(:relay, Relay.Audit, audit)
    end)

    stub(Relay.KeysMock, :public_key, fn :ed25519, "audit-checkpoint" -> {:ok, public} end)

    stub(Relay.KeysMock, :sign, fn :ed25519, "audit-checkpoint", text ->
      {:ok, :crypto.sign(:eddsa, :none, text, [secret, :ed25519])}
    end)

    ref = make_ref()
    pid = self()

    :telemetry.attach(
      ref,
      [:relay, :audit, :mismatch],
      fn _, _, meta, _ -> send(pid, {:mismatch, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    %{public: public, host: host, store: store}
  end

  defp checkpoint(origin, note \\ nil) do
    %{
      id: Relay.Id.generate(),
      origin: origin,
      tree_size: 7,
      root_hash: :crypto.strong_rand_bytes(32),
      signed_note: note || "relay.test checkpoint #{System.unique_integer([:positive])}\n",
      key_ref: "pkcs11:object=audit-checkpoint",
      heartbeat: false
    }
  end

  defp row(checkpoint),
    do: %{
      id: checkpoint.id,
      tree_size: checkpoint.tree_size,
      signed_note: checkpoint.signed_note,
      targets: ["worm_store"]
    }

  defp lease do
    {:ok, result, token} = Store.acquire("audit_checkpoint", "publication-test", 10_000)
    assert result in ["acquired", "renewed"]
    token
  end

  defp leased(fun) do
    committed(fn ->
      try do
        fun.()
      after
        maint_rows!(
          "UPDATE relay.singleton_tasks SET lease_until = now() WHERE name = 'audit_checkpoint' AND leader_node = 'publication-test'"
        )
      end
    end)
  end

  defp step(token, state) do
    ^token = lease()

    {:ok, state, _delay} =
      Checkpointer.run(%{name: "audit_checkpoint", node: "t", fencing_token: token, state: state})

    state
  end

  defp integrate(token, state, ids, tries \\ 50) do
    state = step(token, state)
    found = maint_rows!("SELECT audit_id FROM relay.audit_leaves WHERE audit_id = ANY($1)", [ids])

    cond do
      length(found) == length(ids) -> step(token, state)
      tries == 0 -> flunk("audit records were not integrated")
      true -> Process.sleep(200) && integrate(token, state, ids, tries - 1)
    end
  end

  defp published(origin) do
    maint_rows!(
      """
      SELECT c.id, c.tree_size, c.signed_note FROM relay.audit_checkpoints c
      JOIN relay.audit_checkpoint_publications p ON p.checkpoint_id = c.id
      WHERE c.log_origin = $1 AND p.target = 'worm_store' AND p.status = 'published'
      ORDER BY c.tree_size DESC, c.created_at DESC
      """,
      [origin]
    )
  end

  describe "OP-70 object-locked target" do
    test "OP-70: a checkpoint is written once to the object-locked store and read back", %{
      store: store,
      host: host
    } do
      cp = checkpoint(host <> "/relay/audit/2026")

      assert :ok = S3.publish(cp, store)
      assert {:ok, note} = S3.read(cp, store)
      assert note == cp.signed_note
      assert :ok = S3.publish(cp, store)

      assert {:error, %Relay.Error{code: :publication_conflict}} =
               S3.publish(%{cp | signed_note: "a different note\n"}, store)

      assert {:ok, note} = S3.read(cp, store)
      assert note == cp.signed_note
      assert :ok = S3.check(store)
    end

    test "OP-70: a locked version cannot be deleted", %{store: store, host: host} do
      cp = checkpoint(host <> "/relay/audit/2026")
      :ok = S3.publish(cp, store)
      key = S3.key(cp, store)
      {:ok, version} = ObjectStore.version(store, key)

      assert {:ok, %{status: status}} = ObjectStore.delete(store, key, version)
      assert status in [400, 403]
      assert {:ok, note} = S3.read(cp, store)
      assert note == cp.signed_note
    end

    test "OP-70: a bucket without object lock fails the target check", %{store: store} do
      unlocked = Keyword.put(store, :bucket, "relay-audit-unlocked")
      :ok = ObjectStore.setup_unlocked(unlocked)
      assert {:error, %Relay.Error{code: :target_unlocked}} = S3.check(unlocked)
    end

    test "OP-70: the read-back reports an overwritten or deleted checkpoint as a security event",
         %{store: store, host: host} do
      origin = host <> "/relay/audit/2026"
      cp = checkpoint(origin)
      publishers = [{"worm_store", S3, store}]
      :ok = S3.publish(cp, store)

      assert Readback.compare(origin, row(cp), publishers) == :ok
      refute_received {:mismatch, _}

      {:ok, %{status: 200}} = ObjectStore.overwrite(store, S3.key(cp, store), "forged\n")
      assert Readback.compare(origin, row(cp), publishers) == :ok
      assert_received {:mismatch, %{kind: :published_mismatch, origin: ^origin}}

      {:ok, %{status: 204}} = ObjectStore.delete(store, S3.key(cp, store))
      assert Readback.compare(origin, row(cp), publishers) == :ok
      assert_received {:mismatch, %{kind: :published_missing, origin: ^origin}}
    end

    test "OP-70: an unreachable target holds the read-back cursor", %{store: store, host: host} do
      origin = host <> "/relay/audit/2026"
      down = Keyword.put(store, :endpoint, "http://127.0.0.1:9")

      assert Readback.compare(origin, row(checkpoint(origin)), [{"worm_store", S3, down}]) ==
               :retry

      refute_received {:mismatch, _}
    end
  end

  describe "OP-71 (6) object lock per object and the startup probe" do
    test "OP-71: every checkpoint object carries its own lock mode and retain-until date",
         %{store: store, host: host} do
      clock = Application.fetch_env!(:relay, :clock)
      Application.put_env(:relay, :clock, Relay.ClockMock)
      on_exit(fn -> Application.put_env(:relay, :clock, clock) end)
      now = DateTime.add(DateTime.utc_now(), 600, :second)
      stub(Relay.ClockMock, :utc_now, fn -> now end)
      stub(Relay.ClockMock, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

      cp = checkpoint(host <> "/relay/audit/2026")
      :ok = S3.publish(cp, store)

      expected = DateTime.shift(%{now | microsecond: {0, 0}}, day: 1)
      assert {:ok, {"GOVERNANCE", until}} = ObjectStore.retention(store, S3.key(cp, store))
      assert DateTime.compare(until, expected) == :eq
    end

    test "OP-71: the lock headers follow the bucket's default rule" do
      now = ~U[2026-10-23 10:15:30.123456Z]

      assert S3.lock_headers({"COMPLIANCE", {:years, 10}}, now) == [
               {"x-amz-object-lock-mode", "COMPLIANCE"},
               {"x-amz-object-lock-retain-until-date", "2036-10-23T10:15:30Z"}
             ]

      assert S3.lock_headers({"GOVERNANCE", {:days, 1}}, ~U[2028-02-28 23:00:00Z]) == [
               {"x-amz-object-lock-mode", "GOVERNANCE"},
               {"x-amz-object-lock-retain-until-date", "2028-02-29T23:00:00Z"}
             ]

      assert {:ok, {"GOVERNANCE", {:days, 1}}} =
               S3.lock_rule_of(
                 "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days></DefaultRetention></Rule></ObjectLockConfiguration>"
               )

      assert S3.lock_rule_of(
               "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>"
             ) == :error
    end

    test "OP-71: a checkpoint is not written to a bucket without a default lock rule", %{
      store: store,
      host: host
    } do
      unlocked = Keyword.put(store, :bucket, "relay-audit-unlocked")
      :ok = ObjectStore.setup_unlocked(unlocked)
      cp = checkpoint(host <> "/relay/audit/2026")

      assert {:error, %Relay.Error{code: :target_unlocked}} = S3.publish(cp, unlocked)
      assert {:error, %Relay.Error{code: :publication_missing}} = S3.read(cp, unlocked)
    end

    test "OP-71: the startup probe writes a locked object and reads it back", %{store: store} do
      probe =
        Keyword.put(
          store,
          :prefix,
          "probe-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower) <> "/"
        )

      assert Relay.Config.probe("worm_store", S3, probe) == :ignore
      assert {:ok, [key]} = ObjectStore.keys(probe, probe[:prefix] <> "_probe/")
      assert {:ok, {"GOVERNANCE", _until}} = ObjectStore.retention(probe, key)
    end

    test "OP-71: a production node does not start when its audit target fails the probe", %{
      store: store
    } do
      unlocked = Keyword.put(store, :bucket, "relay-audit-unlocked")
      :ok = ObjectStore.setup_unlocked(unlocked)
      down = Keyword.put(store, :endpoint, "http://127.0.0.1:9")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Relay.Config.probe("worm_store", S3, unlocked) ==
                   {:error, {:audit_target_probe_failed, "worm_store", :target_unlocked}}

          assert Relay.Config.probe("worm_store", S3, down) ==
                   {:error, {:audit_target_probe_failed, "worm_store", :publication_unreachable}}
        end)

      assert log =~ "audit publication target probe failed"

      assert [%{id: {:audit_target_probe, "worm_store"}, start: {Relay.Config, :probe, _}}] =
               Relay.Config.startup_probes(true)

      assert Relay.Config.startup_probes(false) == []
    end

    test "TN-67: the object store secret is read through its callback in a sensitive process", %{
      store: store,
      host: host
    } do
      secret = Relay.Redacted.wrap(store[:secret_access_key])
      via_callback = Keyword.put(store, :secret_access_key, fn -> secret end)

      task =
        Task.async(fn ->
          :ok = S3.publish(checkpoint(host <> "/relay/audit/2026"), via_callback)
          Process.info(self(), :dictionary)
        end)

      assert Task.await(task) == {:dictionary, []}
      assert S3.validate(via_callback) == :ok

      assert S3.validate(
               Keyword.put(
                 store,
                 :secret_access_key,
                 {Relay.Config.SecretFiles, :fetch!, [:audit_s3]}
               )
             ) ==
               :ok
    end
  end

  describe "OP-70 read-back of recorded checkpoints" do
    test "OP-70: recorded checkpoints are read back from the target and compared with the record",
         %{public: public, store: store} do
      leased(fn ->
        tenant = tenant!()
        ids = for _ <- 1..2, do: scoped(tenant.id, "live", fn -> audit!() end)
        state = integrate(lease(), nil, ids)
        origin = state["origin"]
        [[id, size, note] | _] = published(origin)

        assert {:ok, %{"cursors" => %{^origin => [^size, _, _]}}, delay} =
                 Readback.step(nil, 0)

        assert delay == Relay.Audit.Checkpointer.State.interval_ms()
        refute_received {:mismatch, _}

        key = S3.key(%{id: id, origin: origin, tree_size: size}, store)
        {:ok, %{status: 200}} = ObjectStore.overwrite(store, key, note <> "forged\n")

        assert {:ok, _, _} = Readback.step(nil, 0)
        assert_received {:mismatch, %{kind: :published_mismatch, origin: ^origin}}

        assert {:ok, findings} = Verifier.verify(public)
        assert Enum.any?(findings, &(&1.kind == :published_mismatch and &1.origin == origin))
      end)
    end

    test "OP-70: the read-back waits until a checkpoint has settled" do
      leased(fn ->
        state = integrate(lease(), nil, [])
        origin = state["origin"]

        assert {:ok, []} = EscapeHatch.audit_published_after(origin, nil, 3_600, 10)
        assert {:ok, [_ | _]} = EscapeHatch.audit_published_after(origin, nil, 0, 10)
      end)
    end
  end

  describe "E-31 linked audit records" do
    test "E-31: a record carrying Access references is proven against the checkpoint read back from the independent target",
         %{public: public, store: store} do
      leased(fn ->
        tenant = tenant!()
        id = Relay.Id.generate()

        scoped(tenant.id, "live", fn ->
          [["appended"]] =
            rows!(
              "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
              [
                id,
                "test.linked",
                "operator",
                "acc_op_e31",
                "acc_op_e31",
                "acc_rec_e31",
                nil,
                nil,
                nil,
                nil,
                nil,
                digest()
              ]
            )
        end)

        state = integrate(lease(), nil, [id])

        [[origin, index, size, proof]] =
          scoped(tenant.id, "live", fn ->
            rows!(
              "SELECT log_origin, leaf_index, tree_size, proof FROM relay_fn.audit_inclusion_proof($1)",
              [id]
            )
          end)

        assert origin == state["origin"]

        [[checkpoint_id]] =
          maint_rows!(
            "SELECT id FROM relay.audit_checkpoints WHERE log_origin = $1 AND tree_size = $2 ORDER BY created_at LIMIT 1",
            [origin, size]
          )

        assert {:ok, note} = S3.read(%{id: checkpoint_id, origin: origin, tree_size: size}, store)

        assert {:ok, %{origin: ^origin, tree_size: ^size, root_hash: root}} =
                 Relay.Audit.open_checkpoint(note, [Relay.Audit.verifier_key(origin, public)])

        {:ok, [leaf]} = EscapeHatch.audit_leaves(origin, index, 1)

        assert Relay.Audit.verify_inclusion(
                 index,
                 size,
                 Relay.Audit.leaf_hash(origin, index, leaf),
                 proof,
                 root
               )

        assert [["acc_op_e31", "acc_rec_e31"]] =
                 maint_rows!(
                   "SELECT actor_ref, access_record_ref FROM relay.audit_log WHERE id = $1",
                   [id]
                 )
      end)
    end
  end
end
