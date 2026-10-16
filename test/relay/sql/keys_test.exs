defmodule Relay.Sql.KeysTest do
  use Relay.SqlCase, async: false

  defp wrap_key(recipient) do
    one("SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1 LIMIT 1", [
      recipient
    ])
  end

  defp subject_key(recipient, class, wrap \\ nil) do
    row(
      "SELECT * FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)",
      [id(), recipient, class, digest(), wrap || wrap_key(recipient)]
    )
  end

  defp erase(recipient, destroy, restrict) do
    row(
      "SELECT * FROM relay_fn.subject_erase($1, 'dsr_1', $2, $3, $4, $5, $6, $7, $8)",
      [recipient, destroy, restrict, digest() | actor()]
    )
  end

  defp hold(scope, recipient) do
    one("SELECT relay_fn.legal_hold_place($1, $2, $3, 'case 42', $4, $5, $6, $7, $8)", [
      id(),
      scope,
      recipient,
      digest() | actor()
    ])
  end

  test "C-20: a recipient and its profile key are created together and the blind index finds it again" do
    %{recipient: recipient} = scenario!()

    [bidx, bidx_key] =
      row(
        "SELECT external_id_bidx, external_id_bidx_key_id FROM relay.recipients WHERE id = $1",
        [recipient]
      )

    assert row(
             "SELECT * FROM relay_fn.recipient_create($1, 'subscriber', $2, $3, $4, $5, $6, $7)",
             [
               id(),
               bidx,
               bidx_key,
               digest(),
               id(),
               digest(),
               wrap_key(recipient)
             ]
           ) == ["exists", recipient]

    assert rows("SELECT retention_class, state FROM relay.subject_keys WHERE recipient_id = $1", [
             recipient
           ]) ==
             [["recipient_profile", "active"]]
  end

  test "OP-18: one key per subject and retention class" do
    %{recipient: recipient} = scenario!()

    assert ["created", key] = subject_key(recipient, "delivery_record")
    assert subject_key(recipient, "delivery_record") == ["exists", key]

    assert subject_key(id(), "delivery_record", wrap_key(recipient)) == [
             "recipient_not_found",
             nil
           ]
  end

  test "MKT-13: erasure destroys and restricts keys, deletes the recipient and cancels pending deliveries" do
    %{recipient: recipient, notification: notification} = scenario!()
    ["created", _] = subject_key(recipient, "delivery_record")
    pending = delivery!(notification)

    assert erase(recipient, ["recipient_profile"], ["delivery_record"]) == ["erased", 1]

    assert rows(
             "SELECT retention_class, state, wrapped_dek IS NULL FROM relay.subject_keys WHERE recipient_id = $1 ORDER BY retention_class",
             [recipient]
           ) == [
             ["delivery_record", "restricted", false],
             ["recipient_profile", "destroyed", true]
           ]

    assert row(
             "SELECT state, deleted_reason, external_id_bidx IS NULL, external_id_ct IS NOT NULL FROM relay.recipients WHERE id = $1",
             [recipient]
           ) == ["deleted", "erasure", true, true]

    assert row("SELECT failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1", [
             pending
           ]) ==
             ["cancelled", "subject_erasure"]

    assert row(
             "SELECT cancelled_deliveries, backup_copies_expire_at = created_at + interval '35 days' FROM relay.erasure_log WHERE recipient_id = $1",
             [recipient]
           ) == [1, true]

    assert erase(recipient, ["recipient_profile"], []) == ["already_erased", 0]
    assert erase(id(), ["recipient_profile"], []) == ["not_found", 0]
    assert subject_key(recipient, "preference") == ["recipient_deleted", nil]
    assert_rebuilds(pending)
  end

  test "OP-17: an active legal hold blocks erasure until it is released" do
    %{recipient: recipient} = scenario!()

    assert hold("recipient", recipient) == "placed"
    assert hold("recipient", recipient) == "already_active"
    assert hold("recipient", id()) == "recipient_not_found"
    assert erase(recipient, ["recipient_profile"], []) == ["held", 0]

    hold_id = one("SELECT id FROM relay.legal_holds WHERE recipient_id = $1", [recipient])
    release = "SELECT relay_fn.legal_hold_release($1, $2, $3, $4, $5, $6)"
    assert one(release, [hold_id, digest() | actor()]) == "released"
    assert one(release, [hold_id, digest() | actor()]) == "already_released"
    assert one(release, [id(), digest() | actor()]) == "not_found"
    assert erase(recipient, ["recipient_profile"], []) == ["erased", 0]
  end

  test "OP-26: tenant data keys are destroyed only after the tenant is closed" do
    %{tenant: tenant, data_key: data_key} = scenario!()
    destroy = "SELECT relay_fn.tenant_key_destroy($1, 'closure', $2, $3, $4, $5, $6)"

    assert one(destroy, [data_key, digest() | actor()]) == "not_allowed"
    assert hold("tenant", nil) == "placed"

    ctx(tenant, "live")

    ["changed", _] =
      row(
        "SELECT * FROM relay_fn.tenant_set_status('closed', 'offboarded', NULL, $1, $2, $3, $4, $5)",
        [
          digest() | actor()
        ]
      )

    ctx(tenant, "test")
    assert one(destroy, [data_key, digest() | actor()]) == "held"

    hold_id = one("SELECT id FROM relay.legal_holds WHERE scope = 'tenant'")

    "released" =
      one("SELECT relay_fn.legal_hold_release($1, $2, $3, $4, $5, $6)", [
        hold_id,
        digest() | actor()
      ])

    assert one(destroy, [data_key, digest() | actor()]) == "destroyed"
    assert one(destroy, [data_key, digest() | actor()]) == "already_destroyed"
    assert one(destroy, [id(), digest() | actor()]) == "not_found"
    assert one("SELECT wrapped_key IS NULL FROM relay.tenant_keys WHERE id = $1", [data_key])
  end

  test "TN-27: one active key per purpose and receipt day keys wait seven days after their day" do
    tenant = tenant!()
    ctx(tenant)
    data_key = tenant_key!("data")

    register =
      "SELECT relay_fn.tenant_key_register($1, $2, $3, 'pkcs11:token=relay;object=kek', $4, $5, $6, $7, $8, $9)"

    assert one(register, [id(), "data", nil, digest(), digest() | actor()]) == "active_exists"
    assert one(register, [data_key, "data", nil, digest(), digest() | actor()]) == "exists"

    today = Date.utc_today()
    receipt = tenant_key!("receipt_day", today)

    assert one(register, [id(), "receipt_day", today, digest(), digest() | actor()]) ==
             "active_exists"

    assert one("SELECT relay_fn.tenant_key_destroy($1, 'expired', $2, $3, $4, $5, $6)", [
             receipt,
             digest() | actor()
           ]) == "not_allowed"
  end

  test "TN-33: blind index keys rotate through a second key" do
    tenant = tenant!()
    ctx(tenant)

    rotate =
      "SELECT relay_fn.blind_index_key_rotate($1, 'pkcs11:object=bidx2', $2, $3, $4, $5, $6)"

    assert one(rotate, [id(), digest() | actor()]) == "not_active"
    first = blind_index_key!()

    assert one(
             "SELECT relay_fn.blind_index_key_register($1, 'pkcs11:object=b', $2, $3, $4, $5, $6)",
             [id(), digest() | actor()]
           ) == "active_exists"

    next = id()
    assert one(rotate, [next, digest() | actor()]) == "rotating"
    assert one(rotate, [next, digest() | actor()]) == "rotating"

    assert rows("SELECT id, state FROM relay.blind_index_keys ORDER BY created_at, id") == [
             [first, "active"],
             [next, "rotating"]
           ]
  end

  test "TN-26: secrets are stored as references with fingerprints and passwords in URIs are rejected" do
    tenant = tenant!()
    ctx(tenant)
    data_key = tenant_key!("data")
    secret = id()
    fingerprint = digest()

    register =
      "SELECT relay_fn.secret_ref_register($1, $2, $3, $4, $5, 1, $6, $7, $8, $9, $10, $11)"

    assert one(register, [
             secret,
             "provider_credential",
             "pkcs11:object=sms",
             nil,
             nil,
             fingerprint,
             digest() | actor()
           ]) ==
             "created"

    assert one(register, [
             id(),
             "provider_credential",
             "pkcs11:object=sms2",
             nil,
             nil,
             fingerprint,
             digest() | actor()
           ]) ==
             "exists"

    assert one(register, [
             id(),
             "webhook_signing",
             nil,
             digest(),
             data_key,
             digest(),
             digest() | actor()
           ]) ==
             "created"

    assert error_message(register, [
             id(),
             "provider_credential",
             "https://user:pw@host/x",
             nil,
             nil,
             digest(),
             digest() | actor()
           ]) ==
             "invalid_argument"

    retire = "SELECT relay_fn.secret_ref_retire($1, $2, $3, $4, $5, $6)"
    assert one(retire, [secret, digest() | actor()]) == "retired"
    assert one(retire, [secret, digest() | actor()]) == "already_retired"
    assert one(retire, [id(), digest() | actor()]) == "not_found"
  end
end
