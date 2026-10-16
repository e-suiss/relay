defmodule Relay.Audit.CheckpointerTest do
  use Relay.MaintenanceCase, async: false

  import Mox

  alias Relay.Audit.Checkpointer
  alias Relay.Audit.Checkpointer.Verifier
  alias Relay.Platform.Leadership.Store

  setup :set_mox_global

  defmodule Publisher do
    @moduledoc false
    @behaviour Relay.Audit.Checkpointer.Publisher

    @impl true
    def publish(checkpoint, opts) do
      send(Keyword.fetch!(opts, :to), {:published, checkpoint})
      :ok
    end
  end

  setup do
    {public, secret} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, "relay-test-checkpoint"))

    keys = Application.fetch_env!(:relay, :keys)
    audit = Application.get_env(:relay, Relay.Audit)
    Application.put_env(:relay, :keys, Relay.KeysMock)

    Application.put_env(:relay, Relay.Audit,
      log_host: "relay.test",
      checkpoint_key: "audit-checkpoint",
      publishers: [{"worm_store", Publisher, [to: self()]}]
    )

    on_exit(fn ->
      Application.put_env(:relay, :keys, keys)
      Application.put_env(:relay, Relay.Audit, audit)
    end)

    stub(Relay.KeysMock, :public_key, fn :ed25519, "audit-checkpoint" -> {:ok, public} end)

    stub(Relay.KeysMock, :sign, fn :ed25519, "audit-checkpoint", text ->
      {:ok, :crypto.sign(:eddsa, :none, text, [secret, :ed25519])}
    end)

    %{public: public}
  end

  defp lease do
    {:ok, result, token} =
      Store.acquire("audit_checkpoint", "checkpointer-test", 600_000)

    assert result in ["acquired", "renewed"]
    token
  end

  defp step(token, state) do
    {:ok, state, delay} =
      Checkpointer.run(%{name: "audit_checkpoint", node: "t", fencing_token: token, state: state})

    assert delay <= 1_000
    state
  end

  defp integrate(token, state, ids, tries \\ 50) do
    state = step(token, state)
    found = maint_rows!("SELECT audit_id FROM relay.audit_leaves WHERE audit_id = ANY($1)", [ids])

    cond do
      length(found) == length(ids) -> state
      tries == 0 -> flunk("audit records were not integrated")
      true -> retry(token, state, ids, tries)
    end
  end

  defp retry(token, state, ids, tries) do
    Process.sleep(200)
    integrate(token, state, ids, tries - 1)
  end

  test "OP-63: every audit record gets exactly one leaf and the signed root is recomputed from the records",
       %{public: public} do
    committed(fn ->
      tenant = tenant!()
      ids = for _ <- 1..3, do: scoped(tenant.id, "live", fn -> audit!() end)
      token = lease()
      state = integrate(token, nil, ids)
      state = step(token, state)

      assert [[3]] =
               maint_rows!(
                 "SELECT count(*) FROM relay.audit_leaves WHERE audit_id = ANY($1)",
                 [ids]
               )

      origin = state["origin"]
      assert String.starts_with?(origin, "relay.test/relay/audit/")
      assert_received {:published, %{origin: ^origin, signed_note: note}}

      verifier_key = Relay.Audit.verifier_key(origin, public)
      assert {:ok, %{origin: ^origin}} = Relay.Audit.open_checkpoint(note, [verifier_key])

      assert [[_ | _] | _] =
               maint_rows!(
                 """
                 SELECT p.status FROM relay.audit_checkpoint_publications p
                 JOIN relay.audit_checkpoints c ON c.id = p.checkpoint_id
                 WHERE c.log_origin = $1 AND p.target = 'worm_store' AND p.status = 'published'
                 """,
                 [origin]
               )

      assert {:ok, findings} = Verifier.verify(public)
      assert Enum.reject(findings, &(&1.kind == :record_unintegrated)) == []
    end)
  end

  test "OP-63: an inclusion proof of a record verifies against the signed root" do
    committed(fn ->
      tenant = tenant!()
      id = scoped(tenant.id, "live", fn -> audit!() end)
      token = lease()
      state = integrate(token, nil, [id])
      state = step(token, state)

      [[origin, index, size, proof]] =
        scoped(tenant.id, "live", fn ->
          rows!(
            "SELECT log_origin, leaf_index, tree_size, proof FROM relay_fn.audit_inclusion_proof($1)",
            [id]
          )
        end)

      [[leaf]] =
        maint_rows!("SELECT leaf_hash FROM relay.audit_leaves WHERE audit_id = $1", [id])

      [[root]] =
        maint_rows!(
          "SELECT root_hash FROM relay.audit_checkpoints WHERE log_origin = $1 AND tree_size = $2 LIMIT 1",
          [origin, size]
        )

      assert origin == state["origin"]
      assert Relay.Audit.verify_inclusion(index, size, leaf, proof, root)
    end)
  end

  test "TN-46: with nothing new the job only signs a heartbeat after a quiet minute" do
    committed(fn ->
      token = lease()
      state = step(token, step(token, nil))
      [[before]] = maint_rows!("SELECT count(*) FROM relay.audit_checkpoints")
      state = step(token, state)
      assert maint_rows!("SELECT count(*) FROM relay.audit_checkpoints") == [[before]]

      quiet = Map.update!(state, "signed_at_ms", &(&1 - 60_000))
      _ = step(token, quiet)
      [[after_heartbeat]] = maint_rows!("SELECT count(*) FROM relay.audit_checkpoints")
      assert after_heartbeat == before + 1

      assert [[true]] =
               maint_rows!(
                 "SELECT is_heartbeat FROM relay.audit_checkpoints ORDER BY created_at DESC LIMIT 1"
               )
    end)
  end

  test "TN-46: a stale fencing token cannot append leaves" do
    committed(fn ->
      tenant = tenant!()
      _ = scoped(tenant.id, "live", fn -> audit!() end)
      token = lease()

      assert {:ok, "not_leader"} =
               Relay.Platform.Maintenance.EscapeHatch.audit_leaves_append(
                 "relay.test/relay/audit/1999",
                 0,
                 [Relay.Id.generate()],
                 [:crypto.strong_rand_bytes(32)],
                 token - 1
               )
    end)
  end
end
