defmodule Relay.Sql.AuditTest do
  use Relay.SqlCase, async: false

  import Bitwise

  @append "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, 'tenant', NULL, NULL, NULL, NULL, $7)"
  @query "SELECT id, action FROM relay_fn.audit_query($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)"

  defp append(action, audit_id \\ id()) do
    ["operator", actor_ref, on_behalf_of, access_ref] = actor()

    "appended" =
      one(@append, [audit_id, action, "operator", actor_ref, on_behalf_of, access_ref, digest()])

    audit_id
  end

  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600), DateTime.add(now, 3600)}
  end

  test "TN-50: the application role cannot read the audit table directly" do
    tenant = tenant!()
    ctx(tenant)

    assert error_message("SELECT count(*) FROM relay.audit_log") =~ "permission denied"
  end

  test "TN-50: audit_query pages records and writes its own audit_log.read record" do
    tenant = tenant!()
    ctx(tenant)
    [first, second] = Enum.sort([id(), id()])
    append("killswitch.engaged", first)
    append("killswitch.released", second)
    {from, to} = window()
    query = fn after_id -> rows(@query, [from, to, nil, after_id, 10, digest() | actor()]) end
    without_reads = fn records -> Enum.reject(records, &match?([_, "audit_log.read"], &1)) end

    assert without_reads.(query.(nil)) ==
             [[first, "killswitch.engaged"], [second, "killswitch.released"]]

    assert without_reads.(query.(first)) == [[second, "killswitch.released"]]

    assert rows(@query, [from, to, "killswitch.released", nil, 10, digest() | actor()]) ==
             [[second, "killswitch.released"]]

    reads = rows(@query, [from, to, "audit_log.read", nil, 10, digest() | actor()])
    assert length(reads) == 3
  end

  test "TN-48: audit records require the acting identity" do
    tenant = tenant!()
    ctx(tenant)

    assert error_message(@append, [id(), "pii.revealed", "operator", nil, "x", nil, digest()]) ==
             "invalid_argument"
  end

  test "OP-63: leaves are appended without gaps by the leader and the inclusion proof verifies against the root" do
    tenant = tenant!()
    ctx(tenant)
    audit_ids = for n <- 1..5, do: append("pii.revealed.#{<<?a + n>>}")
    hashes = for _ <- audit_ids, do: digest()
    origin = "relay.test/relay/audit/" <> Base.encode16(digest())

    ["acquired", token] =
      row("SELECT * FROM relay_ops.singleton_acquire('audit_checkpoint', 'node_a', '1 minute')")

    append_leaves = "SELECT relay_ops.audit_leaves_append($1, $2, $3, $4, $5)"

    assert one(append_leaves, [origin, 0, audit_ids, hashes, token + 1]) == "not_leader"
    assert one(append_leaves, [origin, 1, audit_ids, hashes, token]) == "index_gap"

    assert one(append_leaves, [origin, 0, Enum.take(audit_ids, 3), Enum.take(hashes, 3), token]) ==
             "appended"

    assert one(append_leaves, [origin, 3, Enum.drop(audit_ids, 3), Enum.drop(hashes, 3), token]) ==
             "appended"

    root = merkle_root(hashes)

    record =
      "SELECT relay_ops.audit_checkpoint_record($1, $2, $3, $4, 'note', 'pkcs11:object=log', $5, $6)"

    assert one(record, [id(), origin, 5, root, false, token]) == "recorded"
    assert one(record, [id(), origin, 5, root, false, token]) == "duplicate"
    assert one(record, [id(), origin, 5, root, true, token]) == "recorded"
    assert one(record, [id(), origin, 4, root, false, token]) == "stale"
    assert one(record, [id(), origin, 6, root, false, token + 1]) == "not_leader"

    for index <- 0..4 do
      [^origin, ^index, 5, proof] =
        row("SELECT * FROM relay_fn.audit_inclusion_proof($1)", [Enum.at(audit_ids, index)])

      assert verify(index, 5, Enum.at(hashes, index), proof) == root
    end

    assert rows("SELECT * FROM relay_fn.audit_inclusion_proof($1)", [id()]) == []
  end

  defp hash_children(left, right), do: :crypto.hash(:sha256, <<1, left::binary, right::binary>>)

  defp merkle_root([leaf]), do: leaf

  defp merkle_root(leaves) do
    k = split(length(leaves))
    {left, right} = Enum.split(leaves, k)
    hash_children(merkle_root(left), merkle_root(right))
  end

  defp split(n), do: split(n, 1)
  defp split(n, k) when k * 2 < n, do: split(n, k * 2)
  defp split(_n, k), do: k

  defp verify(index, size, leaf, proof) do
    {root, _fn, _sn} =
      Enum.reduce(proof, {leaf, index, size - 1}, fn sibling, {r, fnode, snode} ->
        if (fnode &&& 1) == 1 or fnode == snode do
          {fnode, snode} = climb(fnode, snode)
          {hash_children(sibling, r), fnode >>> 1, snode >>> 1}
        else
          {hash_children(r, sibling), fnode >>> 1, snode >>> 1}
        end
      end)

    root
  end

  defp climb(fnode, snode) when (fnode &&& 1) == 0 and fnode != 0,
    do: climb(fnode >>> 1, snode >>> 1)

  defp climb(fnode, snode), do: {fnode, snode}
end
