defmodule Relay.Audit.VerifierTest do
  use Relay.MaintenanceCase, async: false

  import Mox

  alias Relay.Audit.Checkpointer.State
  alias Relay.Audit.Checkpointer.Verifier

  setup :set_mox_global

  setup do
    {public, secret} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, "relay-test-checkpoint"))

    audit = Application.get_env(:relay, Relay.Audit)
    keys = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)
    stub(Relay.KeysMock, :public_key, fn :ed25519, "audit-checkpoint" -> {:ok, public} end)

    Application.put_env(:relay, Relay.Audit,
      log_host: "relay.test",
      checkpoint_key: "audit-checkpoint",
      publishers: []
    )

    on_exit(fn ->
      Application.put_env(:relay, Relay.Audit, audit)
      Application.put_env(:relay, :keys, keys)
    end)

    origin =
      "v" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower) <> ".test/relay/audit/2026"

    %{public: public, secret: secret, origin: origin}
  end

  defp records!(count) do
    tenant = tenant!()
    ids = for _ <- 1..count, do: scoped(tenant.id, "live", fn -> audit!() end)

    "SELECT tenant_id, environment::text, id, created_at, record_digest FROM relay.audit_log WHERE id = ANY($1)"
    |> maint_rows!([ids])
    |> Enum.map(fn [tenant_id, environment, id, created_at, digest] ->
      %{
        tenant_id: tenant_id,
        environment: environment,
        audit_id: id,
        created_at: created_at,
        record_digest: digest
      }
    end)
    |> Enum.sort_by(&Enum.find_index(ids, fn id -> id == &1.audit_id end))
  end

  defp leaves(origin, records),
    do:
      records
      |> Enum.with_index()
      |> Enum.map(fn {record, pos} ->
        {pos, record, Relay.Audit.leaf_hash(origin, pos, record)}
      end)

  defp store_leaves!(origin, leaves) do
    for {index, record, hash} <- leaves do
      maint_rows!(
        """
        INSERT INTO relay.audit_leaves (log_origin, leaf_index, audit_tenant_id, audit_environment,
          audit_id, audit_created_at, leaf_hash, integrated_at)
        VALUES ($1, $2, $3, $4::text::relay.environment, $5, $6, $7, now())
        """,
        [
          origin,
          index,
          record.tenant_id,
          record.environment,
          record.audit_id,
          record.created_at,
          hash
        ]
      )
    end

    origin |> State.new() |> State.append(Enum.map(leaves, fn {_, _, hash} -> hash end))
  end

  defp note(origin, size, root, public, secret) do
    {:ok, note} =
      Relay.Audit.sign_note(
        Relay.Audit.checkpoint_text(origin, size, root),
        origin,
        public,
        &{:ok, :crypto.sign(:eddsa, :none, &1, [secret, :ed25519])}
      )

    note
  end

  defp store_checkpoint!(origin, size, root, note) do
    maint_rows!(
      """
      INSERT INTO relay.audit_checkpoints (id, log_origin, tree_size, root_hash, signed_note,
        key_ref, is_heartbeat, created_at)
      VALUES ($1, $2, $3, $4, $5, 'pkcs11:object=audit-checkpoint', false, now())
      """,
      [Relay.Id.generate(), origin, size, root, note]
    )
  end

  defp signed!(state, ctx) do
    root = State.root(state)

    store_checkpoint!(
      ctx.origin,
      state.tree_size,
      root,
      note(ctx.origin, state.tree_size, root, ctx.public, ctx.secret)
    )
  end

  defp findings(ctx) do
    assert {:ok, findings} = Verifier.verify(ctx.public)

    for finding <- findings,
        finding.origin == ctx.origin,
        do: {finding.kind, finding.detail}
  end

  defp tampered(leaves, index, fun),
    do: List.update_at(leaves, index, fun)

  describe "OP-63 (3) database-side tamper detection" do
    test "OP-63: an untouched log verifies without findings", ctx do
      committed(fn ->
        ctx.origin |> store_leaves!(leaves(ctx.origin, records!(3))) |> signed!(ctx)
        assert findings(ctx) == []
      end)
    end

    test "OP-63: a leaf that no longer matches its record is a leaf mismatch", ctx do
      committed(fn ->
        leaves =
          ctx.origin
          |> leaves(records!(3))
          |> tampered(1, fn {pos, record, _hash} -> {pos, record, digest()} end)

        ctx.origin |> store_leaves!(leaves) |> signed!(ctx)
        assert findings(ctx) == [leaf_mismatch: 1]
      end)
    end

    test "OP-63: a recorded root that differs from the root rebuilt from the leaves is a root mismatch",
         ctx do
      committed(fn ->
        state = store_leaves!(ctx.origin, leaves(ctx.origin, records!(3)))
        forged = digest()
        note = note(ctx.origin, state.tree_size, forged, ctx.public, ctx.secret)
        store_checkpoint!(ctx.origin, state.tree_size, forged, note)

        assert findings(ctx) == [root_mismatch: 3]
      end)
    end

    test "OP-63: a missing leaf position is an index gap", ctx do
      committed(fn ->
        [first, _second, {_pos, record, hash}] = leaves(ctx.origin, records!(3))

        ctx.origin |> store_leaves!([first, {2, record, hash}]) |> signed!(ctx)
        assert findings(ctx) == [index_gap: 1]
      end)
    end

    test "OP-63: a leaf whose audit record is gone is a missing record", ctx do
      committed(fn ->
        leaves =
          ctx.origin
          |> leaves(records!(2))
          |> tampered(1, fn {pos, record, hash} ->
            {pos, %{record | audit_id: Relay.Id.generate()}, hash}
          end)

        ctx.origin |> store_leaves!(leaves) |> signed!(ctx)
        assert findings(ctx) == [record_missing: 1]
      end)
    end

    test "OP-63: a checkpoint whose signed note does not verify is an invalid note", ctx do
      committed(fn ->
        state = store_leaves!(ctx.origin, leaves(ctx.origin, records!(2)))
        root = State.root(state)
        {other, other_secret} = :crypto.generate_key(:eddsa, :ed25519)
        forged = note(ctx.origin, state.tree_size, root, other, other_secret)
        store_checkpoint!(ctx.origin, state.tree_size, root, forged)

        assert findings(ctx) == [note_invalid: 2]
      end)
    end

    test "OP-63: a mismatch is reported as a security event", ctx do
      committed(fn ->
        store_leaves!(ctx.origin, leaves(ctx.origin, records!(1)))
        forged = digest()

        store_checkpoint!(
          ctx.origin,
          1,
          forged,
          note(ctx.origin, 1, forged, ctx.public, ctx.secret)
        )

        pid = self()
        ref = make_ref()

        :telemetry.attach(
          ref,
          [:relay, :audit, :mismatch],
          fn _, _, meta, _ -> send(pid, {:mismatch, meta}) end,
          nil
        )

        try do
          assert {:ok, %{"findings" => count}, _delay} =
                   Verifier.run(%{name: "audit_verify", node: "t", fencing_token: 1, state: nil})

          assert count >= 1
          origin = ctx.origin
          assert_received {:mismatch, %{kind: :root_mismatch, origin: ^origin}}
        after
          :telemetry.detach(ref)
        end
      end)
    end
  end
end
