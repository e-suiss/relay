defmodule Relay.Tenancy.KillSwitchStoreTest do
  use Relay.SqlCase, async: false

  @engage "SELECT * FROM relay_fn.kill_switch_engage($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21)"
  @release "SELECT * FROM relay_fn.kill_switch_release($1, $2, $3, $4, $5, $6, $7, $8)"
  @replace "SELECT * FROM relay_fn.kill_switch_replace($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)"

  defp later(seconds \\ 3600), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp engage(attrs) do
    a =
      Map.merge(
        %{
          id: id(),
          scope_kind: "tenant",
          scope_ref: nil,
          channel: nil,
          target_kind: "all",
          target_ref: nil,
          message_class: nil,
          security_approval_ref: nil,
          state: "off",
          canary_percent: nil,
          paused_until: nil,
          reason: "incident 42",
          ticket_ref: "INC-42",
          expires_at: later(),
          no_ttl_approval_ref: nil,
          origin: "operator"
        },
        Map.new(attrs)
      )

    row(@engage, [
      a.id,
      a.scope_kind,
      a.scope_ref,
      a.channel,
      a.target_kind,
      a.target_ref,
      a.message_class,
      a.security_approval_ref,
      a.state,
      a.canary_percent,
      a.paused_until,
      a.reason,
      a.ticket_ref,
      a.expires_at,
      a.no_ttl_approval_ref,
      a.origin,
      digest() | actor()
    ])
  end

  defp installation, do: one("SELECT relay_private.installation_tenant_id()")

  defp audit_actions(target_id) do
    now = DateTime.utc_now()

    for [action, target] <-
          rows(
            "SELECT action, target_id FROM relay_fn.audit_query($1, $2, NULL, NULL, 1000, $3, $4, $5, $6, $7) ORDER BY created_at, id",
            [DateTime.add(now, -3600), DateTime.add(now, 3600), digest() | actor()]
          ),
        target == uuid(target_id),
        do: action
  end

  defp outbox_types(target_id) do
    for [type] <-
          rows(
            "SELECT event_type FROM relay.outbox_events WHERE stream_key = $1 ORDER BY seq",
            ["killswitch:" <> uuid(target_id)]
          ),
        do: type
  end

  defp uuid(id), do: Relay.Id.to_string(id)

  defp generation, do: one("SELECT generation FROM relay.kill_switch_generation")

  setup do
    tenant = tenant!()
    "active" = ctx(tenant, "live")
    %{tenant: tenant}
  end

  describe "TN-36 five dimensions" do
    test "TN-36: a record carries scope, channel, target, class and state with reason, creator, expiry and ticket" do
      stn = id()

      ["created", ^stn, _] =
        row("SELECT * FROM relay_fn.subtenant_upsert($1, $2, $3, $4, $5, $6, $7, $8)", [
          stn,
          "org_1",
          "Org",
          digest() | actor()
        ])

      before = generation()
      ksw = id()
      account = Relay.Id.to_string(id())

      assert ["engaged", ^ksw, gen] =
               engage(
                 id: ksw,
                 scope_kind: "subtenant",
                 scope_ref: uuid(stn),
                 channel: "sms",
                 target_kind: "provider_account",
                 target_ref: account,
                 message_class: "marketing",
                 state: "canary",
                 canary_percent: 25
               )

      assert gen == before + 1

      assert [
               [
                 "subtenant",
                 scope_ref,
                 "sms",
                 "provider_account",
                 ^account,
                 "marketing",
                 "canary",
                 25,
                 "incident 42",
                 "INC-42",
                 "operator",
                 "acc_op_1",
                 %DateTime{},
                 "active"
               ]
             ] =
               rows(
                 "SELECT scope_kind, scope_ref, channel, target_kind, target_ref, message_class, state, canary_percent, reason, ticket_ref, origin, created_by_ref, expires_at, status FROM relay.kill_switches WHERE id = $1",
                 [ksw]
               )

      assert scope_ref == uuid(stn)
    end

    test "TN-36: a sub-tenant scope must name an existing sub-tenant and a platform record lives only in the installation scope" do
      assert ["scope_not_found", nil, nil] =
               engage(scope_kind: "subtenant", scope_ref: uuid(id()))

      assert ["scope_not_found", nil, nil] = engage(scope_kind: "subtenant", scope_ref: "x")
      assert ["invalid_scope", nil, nil] = engage(scope_kind: "platform")

      "active" = ctx(installation(), "live")
      assert ["engaged", _, _] = engage(scope_kind: "platform")
      assert ["invalid_scope", nil, nil] = engage(scope_kind: "tenant")
    end

    test "TN-36: the same identifier engaged again returns the existing record" do
      ksw = id()
      assert ["engaged", ^ksw, _] = engage(id: ksw)
      assert ["exists", ^ksw, _] = engage(id: ksw)
    end
  end

  describe "TN-41 reason and TTL" do
    test "TN-41: an empty reason is refused by the function and by the table constraint" do
      assert ["reason_required", nil, nil] = engage(reason: "  ")
      assert ["reason_required", nil, nil] = engage(reason: nil)

      [ksw] = [id()]
      assert ["engaged", ^ksw, _] = engage(id: ksw)

      assert error_message(
               "INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, target_kind, state, reason, origin, created_by_ref, expires_at, status, created_at) SELECT tenant_id, environment, uuidv7(), 'tenant', 'all', 'off', ' ', 'operator', 'x', now() + interval '1 hour', 'active', now() FROM relay.kill_switches WHERE id = $1",
               [ksw]
             ) =~ "permission denied"

      admin = connect(:admin)

      rolled_back(admin, fn ->
        assert error_message(
                 "INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, target_kind, state, reason, origin, created_by_ref, expires_at, status, created_at) VALUES (uuidv7(), 'live', uuidv7(), 'tenant', 'all', 'off', ' ', 'operator', 'x', now() + interval '1 hour', 'active', now())"
               ) =~ "kill_switches_reason_check"
      end)
    end

    test "TN-41: a record without TTL needs an explicit approval, also in the table" do
      assert ["ttl_required", nil, nil] = engage(expires_at: nil)
      assert ["engaged", _, _] = engage(expires_at: nil, no_ttl_approval_ref: "CAB-1")

      admin = connect(:admin)

      rolled_back(admin, fn ->
        assert error_message(
                 "INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, target_kind, state, reason, origin, created_by_ref, expires_at, status, created_at) VALUES (uuidv7(), 'live', uuidv7(), 'tenant', 'all', 'off', 'r', 'operator', 'x', NULL, 'active', now())"
               ) =~ "kill_switches_no_ttl_approval_check"
      end)
    end

    test "TN-41: a release needs a reason and an approval and is written once" do
      ksw = id()
      ["engaged", ^ksw, _] = engage(id: ksw)

      assert ["reason_required", nil] = row(@release, [ksw, " ", "CAB-2", digest() | actor()])
      assert ["approval_required", nil] = row(@release, [ksw, "fixed", nil, digest() | actor()])
      assert ["released", _] = row(@release, [ksw, "fixed", "CAB-2", digest() | actor()])
      assert ["already_released", _] = row(@release, [ksw, "fixed", "CAB-2", digest() | actor()])
      assert ["not_found", nil] = row(@release, [id(), "fixed", "CAB-2", digest() | actor()])

      assert [["released", "fixed", "CAB-2", "acc_op_1"]] =
               rows(
                 "SELECT status, release_reason, release_approval_ref, released_by_ref FROM relay.kill_switches WHERE id = $1",
                 [ksw]
               )
    end

    test "TN-41: the guard trigger allows only the release and stops any other change, delete or truncate" do
      admin = connect(:admin)

      rolled_back(admin, fn ->
        ksw =
          one(
            "INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, target_kind, state, reason, origin, created_by_ref, expires_at, status, created_at) VALUES (uuidv7(), 'live', uuidv7(), 'tenant', 'all', 'off', 'r', 'operator', 'x', now() + interval '1 hour', 'active', now()) RETURNING id"
          )

        assert error_message("UPDATE relay.kill_switches SET reason = 'other' WHERE id = $1", [
                 ksw
               ]) =~
                 "invariant_violation"

        assert error_message(
                 "UPDATE relay.kill_switches SET status = 'released', released_at = now(), released_by_ref = 'x', release_reason = 'r', release_approval_ref = 'a', state = 'on' WHERE id = $1",
                 [ksw]
               ) =~ "invariant_violation"

        assert error_message("DELETE FROM relay.kill_switches WHERE id = $1", [ksw]) =~
                 "invariant_violation"

        assert error_message("TRUNCATE relay.kill_switches") =~ "invariant_violation"

        assert [[1]] =
                 rows(
                   "WITH u AS (UPDATE relay.kill_switches SET status = 'released', released_at = now(), released_by_ref = 'x', release_reason = 'r', release_approval_ref = 'a' WHERE id = $1 RETURNING 1) SELECT count(*)::int FROM u",
                   [ksw]
                 )

        assert error_message(
                 "UPDATE relay.kill_switches SET release_reason = 'again' WHERE id = $1",
                 [ksw]
               ) =~ "invariant_violation"
      end)
    end

    test "TN-41: a relaxing replacement needs approval, a tightening one does not" do
      ksw = id()
      ["engaged", ^ksw, _] = engage(id: ksw, state: "canary", canary_percent: 20)

      assert ["approval_required", nil, nil] =
               row(@replace, [
                 ksw,
                 id(),
                 "canary",
                 30,
                 nil,
                 "wider",
                 later(),
                 nil,
                 nil,
                 digest() | actor()
               ])

      new = id()

      assert ["replaced", ^new, _] =
               row(@replace, [
                 ksw,
                 new,
                 "off",
                 nil,
                 nil,
                 "stop",
                 later(),
                 nil,
                 nil,
                 digest() | actor()
               ])

      assert [["released", "superseded:" <> _]] =
               rows(
                 "SELECT status, release_approval_ref FROM relay.kill_switches WHERE id = $1",
                 [ksw]
               )

      assert [["active", "off", ^ksw]] =
               rows(
                 "SELECT status, state, supersedes_id FROM relay.kill_switches WHERE id = $1",
                 [new]
               )

      newer = id()

      assert ["replaced", ^newer, _] =
               row(@replace, [
                 new,
                 newer,
                 "on",
                 nil,
                 nil,
                 "done",
                 later(),
                 nil,
                 "CAB-3",
                 digest() | actor()
               ])

      assert ["already_released", nil, _] =
               row(@replace, [
                 new,
                 id(),
                 "off",
                 nil,
                 nil,
                 "x",
                 later(),
                 nil,
                 nil,
                 digest() | actor()
               ])
    end
  end

  describe "TN-41 schema" do
    test "TN-41: the reason, TTL approval, security approval, canary and paused_until constraints and the guard trigger exist" do
      constraints =
        for [name] <-
              rows(
                "SELECT conname::text FROM pg_constraint WHERE conrelid = 'relay.kill_switches'::regclass AND contype = 'c'"
              ),
            do: name

      for name <- ~w(kill_switches_reason_check kill_switches_no_ttl_approval_check
                     kill_switches_security_approval_check kill_switches_canary_percent_check
                     kill_switches_canary_percent_range_check kill_switches_paused_until_check
                     kill_switches_paused_until_expiry_check kill_switches_paused_until_infinity_check
                     kill_switches_release_check),
          do: assert(name in constraints, name)

      triggers =
        for [name] <-
              rows(
                "SELECT tgname::text FROM pg_trigger WHERE tgrelid = 'relay.kill_switches'::regclass AND NOT tgisinternal"
              ),
            do: name

      assert Enum.sort(triggers) ==
               ~w(kill_switches_guard kill_switches_no_delete kill_switches_no_truncate)
    end
  end

  describe "TN-42 security approval" do
    test "TN-42: stopping security needs its own approval, also in the table" do
      assert ["security_approval_required", nil, nil] = engage(message_class: "security")

      assert ["engaged", _, _] =
               engage(message_class: "security", security_approval_ref: "SEC-1")

      admin = connect(:admin)

      rolled_back(admin, fn ->
        assert error_message(
                 "INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, target_kind, message_class, state, reason, origin, created_by_ref, expires_at, status, created_at) VALUES (uuidv7(), 'live', uuidv7(), 'tenant', 'all', 'security', 'off', 'r', 'operator', 'x', now() + interval '1 hour', 'active', now())"
               ) =~ "kill_switches_security_approval_check"
      end)
    end
  end

  describe "TN-43 dead-man record" do
    test "TN-43: one automatic pause per scope, without end and only from the dead-man origin" do
      infinity =
        "SELECT * FROM relay_fn.kill_switch_engage($1, 'tenant', NULL, NULL, 'all', NULL, NULL, NULL, 'paused_until', NULL, 'infinity', 'dead_man: 12.0× over 1h baseline', NULL, NULL, 'TN-43', $2, $3, 'system', 'system:dead_man', 'system:dead_man', NULL)"

      ksw = id()
      assert ["engaged", ^ksw, _] = row(infinity, [ksw, "dead_man", digest()])
      assert ["dead_man_active", ^ksw, _] = row(infinity, [id(), "dead_man", digest()])
      assert error_message(infinity, [id(), "operator", digest()]) =~ "invalid_argument"
      assert audit_actions(ksw) == ["killswitch.auto_paused"]
      assert outbox_types(ksw) == ["killswitch.auto_paused"]
    end
  end

  describe "TN-47 audit records" do
    test "TN-47: engage, release and replace are audited and go to the outbox" do
      ksw = id()
      ["engaged", ^ksw, _] = engage(id: ksw)
      new = id()

      ["replaced", ^new, _] =
        row(@replace, [
          ksw,
          new,
          "off",
          nil,
          nil,
          "longer",
          later(7200),
          nil,
          nil,
          digest() | actor()
        ])

      ["released", _] = row(@release, [new, "over", "CAB-4", digest() | actor()])

      assert Enum.sort(audit_actions(ksw)) == ["killswitch.engaged", "killswitch.released"]
      assert Enum.sort(audit_actions(new)) == ["killswitch.engaged", "killswitch.released"]
      assert outbox_types(ksw) == ["killswitch.engaged", "killswitch.released"]
      assert outbox_types(new) == ["killswitch.engaged", "killswitch.released"]
    end

    test "TN-47: a bulk cancel command is one audit record" do
      ksw = id()
      ["engaged", ^ksw, _] = engage(id: ksw)

      assert "appended" =
               one(
                 "SELECT relay_fn.audit_append($1, 'killswitch.bulk_cancelled', $2, $3, $4, $5, 'kill_switch', $6, 'wrong batch', NULL, NULL, $7)",
                 [id() | actor()] ++ [uuid(ksw), digest()]
               )

      assert Enum.sort(audit_actions(ksw)) == ["killswitch.bulk_cancelled", "killswitch.engaged"]
    end
  end

  describe "S-48 shared reading" do
    test "S-48: a tenant sees its own records and the platform records, never another tenant's" do
      mine = id()
      ["engaged", ^mine, _] = engage(id: mine)
      "active" = ctx(installation(), "live")
      platform = id()
      ["engaged", ^platform, _] = engage(id: platform, scope_kind: "platform")

      other = tenant!()
      "active" = ctx(other, "live")
      theirs = id()
      ["engaged", ^theirs, _] = engage(id: theirs)

      listed =
        for [id] <- rows("SELECT id FROM relay_fn.kill_switch_list(false, NULL, 100)"), do: id

      assert platform in listed
      assert theirs in listed
      refute mine in listed

      "active" = ctx(other, "test")

      listed =
        for [id] <- rows("SELECT id FROM relay_fn.kill_switch_list(false, NULL, 100)"), do: id

      assert platform in listed
      refute theirs in listed
    end

    test "TN-39: the snapshot holds every record in force across tenants with the generation" do
      ksw = id()
      ["engaged", ^ksw, gen] = engage(id: ksw)
      released = id()
      ["engaged", ^released, _] = engage(id: released)
      ["released", gen2] = row(@release, [released, "over", "CAB-5", digest() | actor()])
      assert gen2 == gen + 2

      snapshot = rows("SELECT generation, id FROM relay_ops.kill_switch_snapshot()")
      assert Enum.all?(snapshot, fn [g, _] -> g == gen2 end)
      ids = Enum.map(snapshot, &List.last/1)
      assert ksw in ids
      refute released in ids
    end
  end
end
