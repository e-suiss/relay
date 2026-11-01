defmodule Relay.Sql.PreferencesTest do
  use Relay.SqlCase, async: false

  @create "SELECT * FROM relay_fn.category_create($1, $2, $3, $4, $5, $6, $7, $8::text::interval, $9, $10::text::interval, $11, $12, $13, $14, $15, $16, $17)"
  @update "SELECT * FROM relay_fn.category_update($1, $2, $3, $4, $5, $6::text::interval, $7, $8::text::interval, $9, $10, $11, $12, $13, $14, $15, $16)"
  @subtenant "SELECT * FROM relay_fn.category_subtenant_put($1, $2, $3, $4, $5, $6::text::interval, $7, $8::text::interval, $9, $10, $11, $12, $13, $14)"
  @archive "SELECT * FROM relay_fn.category_archive($1, $2, $3, $4, $5, $6)"
  @set "SELECT * FROM relay_fn.preference_set($1, $2, $3, $4, $5, $6, $7, 'acc_user_1')"
  @profile "SELECT * FROM relay_fn.preference_profile_put($1, $2, '[]', NULL, $3, $4, $5, $6)"
  @consent "SELECT * FROM relay_fn.consent_record($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, NULL, 'access', $14)"
  @suppress "SELECT * FROM relay_fn.suppression_add($1, $2, $3, $4, NULL, $5, $6, $7, $8, $9, $10, $11)"
  @lift "SELECT * FROM relay_fn.suppression_lift($1, $2, $3, 'reviewed', $4, $5, $6, $7, $8)"
  @match "SELECT * FROM relay_fn.suppression_match($1, $2) ORDER BY reason"
  @audit "SELECT action, target_id FROM relay_fn.audit_query($1, $2, $3, NULL, 10, $4, $5, $6, $7, $8)"
  @platform "SELECT * FROM relay_ops.tenant_create($1, $2, $3, 'general', 'Europe/Istanbul', 'tr', NULL, 'access', $4, $5, $6, $7, $8)"
  @changes "SELECT old_value, new_value, writer FROM relay.preference_changes WHERE preference_id = $1 ORDER BY created_at, id"
  @consent_key "SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1 LIMIT 1"
  @erase "SELECT * FROM relay_fn.subject_erase($1, 'dsr_1', $2, $3, $4, $5, $6, $7, $8)"

  defp category(key, class, opts \\ []) do
    row(@create, [
      id(),
      key,
      Keyword.get(opts, :name, "Name of " <> key),
      class,
      Keyword.get(opts, :locked, false),
      Keyword.get(opts, :enabled, true),
      Keyword.get(opts, :defaults, %{}),
      opts[:expires_in],
      opts[:limit],
      opts[:window],
      opts[:fate],
      Keyword.get(opts, :digest_allowed, false),
      digest() | actor()
    ])
  end

  defp update(key, opts) do
    row(@update, [
      key,
      Keyword.get(opts, :name, "Name of " <> key),
      Keyword.get(opts, :locked, false),
      Keyword.get(opts, :enabled, true),
      Keyword.get(opts, :defaults, %{}),
      opts[:expires_in],
      opts[:limit],
      opts[:window],
      opts[:fate],
      Keyword.get(opts, :digest_allowed, false),
      opts[:version],
      digest() | actor()
    ])
  end

  defp archive(key), do: row(@archive, [key, digest() | actor()])

  defp subtenant_put(key, subtenant, enabled) do
    row(@subtenant, [id(), key, subtenant, enabled, nil, nil, nil, nil, nil, digest() | actor()])
  end

  defp set(recipient, level, key, channel, value, writer \\ "subscriber"),
    do: row(@set, [id(), recipient, level, key, channel, value, writer])

  defp profile(recipient, quiet, email, digest, writer, version \\ nil),
    do: row(@profile, [recipient, quiet, email, digest, writer, version])

  defp audit(action) do
    now = DateTime.utc_now()
    rows(@audit, [DateTime.add(now, -3600), DateTime.add(now, 3600), action, digest() | actor()])
  end

  defp subtenant! do
    ["created", subtenant, _] =
      row("SELECT * FROM relay_fn.subtenant_upsert($1, $2, 'Brand', $3, $4, $5, $6, $7)", [
        id(),
        "org_" <> Base.encode16(digest()),
        digest() | actor()
      ])

    subtenant
  end

  defp evidence_key(recipient) do
    wrap = one(@consent_key, [recipient])

    ["created", key] =
      row("SELECT * FROM relay_fn.subject_key_create($1, $2, 'commercial_consent', $3, $4)", [
        id(),
        recipient,
        digest(),
        wrap
      ])

    key
  end

  defp consent(recipient, status, sequence, opts \\ []) do
    evidence? = Keyword.get(opts, :evidence, status == "active")

    row(@consent, [
      id(),
      recipient,
      opts[:brand],
      Keyword.get(opts, :channel, "email"),
      status,
      if(evidence?, do: "explicit_opt_in"),
      if(evidence?, do: "individual"),
      Keyword.get(opts, :source, "access"),
      sequence,
      DateTime.utc_now(),
      if(evidence?, do: digest()),
      if(evidence?, do: :crypto.strong_rand_bytes(48)),
      if(evidence?, do: opts[:key]),
      "evt_" <> Integer.to_string(sequence)
    ])
  end

  defp suppress(target, bidx_key, reason, expires_at \\ nil) do
    row(@suppress, [id(), "email", target, bidx_key, reason, expires_at, digest() | actor()])
  end

  defp lift(suppression, lifter, step_up \\ nil),
    do: one(@lift, [suppression, lifter, step_up, digest() | actor()])

  describe "PC-57 (1) PC-57 (2) categories" do
    test "PC-57, PC-1: a category is unique by key, keeps its class and is audited" do
      tenant = tenant!()
      ctx(tenant)

      assert ["created", category_id, 1] = category("orders", "transactional")
      assert ["key_conflict", ^category_id, 1] = category("orders", "marketing")

      assert [["category.created", text]] = audit("category.created")
      assert text == Relay.Id.to_string(category_id)

      assert error_message("UPDATE relay.categories SET message_class = 'marketing'") =~
               "permission denied"
    end

    test "PC-6: security is always locked, marketing and social are never locked" do
      ctx(tenant!())

      assert ["created", _, 1] = category("alerts", "security", locked: false)
      assert one("SELECT locked FROM relay.categories WHERE key = 'alerts'") == true
      assert ["lock_not_allowed", nil, nil] = category("promo", "marketing", locked: true)
      assert ["lock_not_allowed", nil, nil] = category("feed", "social", locked: true)
      assert ["created", _, 1] = category("billing", "transactional", locked: true)
    end

    test "PC-14: a marketing default cannot be on where prior consent is required" do
      ctx(tenant!())

      for channel <- ~w(email sms voice whatsapp) do
        assert ["default_forbidden", nil, nil] =
                 category("promo_" <> channel, "marketing", defaults: %{channel => "on"})
      end

      assert ["created", _, 1] = category("promo", "marketing", defaults: %{"push" => "on"})
      assert ["invalid_settings", nil, nil] = category("bad", "social", defaults: %{"x" => "on"})
    end

    test "PC-57 (4), PC-50: expiry, frequency and digest settings follow the class" do
      ctx(tenant!())

      assert ["invalid_settings", nil, nil] = category("otp", "security", expires_in: "PT10M")
      assert ["invalid_settings", nil, nil] = category("late", "social", expires_in: "P31D")

      assert ["invalid_settings", nil, nil] =
               category("bill", "transactional", limit: 3, window: "PT1H", fate: "drop")

      assert ["invalid_settings", nil, nil] = category("feed", "social", digest_allowed: true)

      cap = [limit: 2, window: "P1D", fate: "drop"]
      assert ["created", _, 1] = category("news", "marketing", [expires_in: "P2D"] ++ cap)

      assert ["created", _, 1] = category("ops", "operational", digest_allowed: true)
    end

    test "PC-11: a lock change has its own audit record; an archived category is kept" do
      ctx(tenant!())
      ["created", category_id, 1] = category("billing", "transactional")

      assert update("billing", name: "Billing") == ["updated", 2]
      assert update("billing", name: "Billing") == ["unchanged", 2]
      locked = [name: "Billing", locked: true]
      assert update("billing", [version: 1] ++ locked) == ["version_conflict", 2]
      assert update("billing", [version: 2] ++ locked) == ["updated", 3]
      assert [["category.lock_changed", _]] = audit("category.lock_changed")
      assert [["category.updated", _]] = audit("category.updated")

      assert archive("billing") == ["archived", 4]
      assert archive("billing") == ["already_archived", 4]
      assert update("billing", name: "Other") == ["archived", 4]
      assert one("SELECT count(*) FROM relay.categories WHERE id = $1", [category_id]) == 1
    end

    test "PC-7: a subtenant setting overrides only its own fields and is audited" do
      ctx(tenant!())
      subtenant = subtenant!()
      ["created", _, 1] = category("news", "marketing")

      assert subtenant_put("news", subtenant, false) == ["created", 1]
      assert subtenant_put("news", subtenant, false) == ["unchanged", 1]
      assert subtenant_put("news", subtenant, nil) == ["updated", 2]
      assert [_, _] = audit("category_subtenant_setting.changed")
      assert subtenant_put("news", id(), true) == ["subtenant_not_found", nil]
      assert subtenant_put("missing", subtenant, true) == ["not_found", nil]
    end
  end

  describe "PC-57 (3) built-in security category" do
    test "PC-57 (3): an Access platform tenant opens with a locked built-in security category" do
      tenant = id()
      access_id = "acc_" <> Base.encode16(tenant)
      ["created", ^tenant] = row(@platform, [tenant, access_id, region(), digest() | actor()])

      for environment <- ~w(live test) do
        ctx(tenant, environment)

        assert rows("SELECT key, message_class, locked, builtin, state FROM relay.categories") ==
                 [["security", "security", true, true, "active"]]

        assert archive("security") == ["builtin", 1]
      end
    end

    test "PC-57 (3): other tenants open without categories" do
      ctx(tenant!())
      assert one("SELECT count(*) FROM relay.categories") == 0
    end
  end

  describe "PC-57 (5) preferences" do
    test "PC-15: a tenant writes only opt_out; unset is kept as a value; every write is logged" do
      s = scenario!()
      ["created", _, 1] = category("news", "marketing")

      assert ["direction_forbidden", nil, nil] =
               set(s.recipient, "category_channel", "news", "push", "opt_in", "tenant")

      assert ["set", preference, 1] =
               set(s.recipient, "category_channel", "news", "push", "opt_out", "tenant")

      assert ["unchanged", ^preference, 1] =
               set(s.recipient, "category_channel", "news", "push", "opt_out", "tenant")

      assert ["set", ^preference, 2] =
               set(s.recipient, "category_channel", "news", "push", "unset")

      assert one("SELECT value FROM relay.preferences WHERE id = $1", [preference]) == "unset"

      assert rows(@changes, [preference]) ==
               [[nil, "opt_out", "tenant"], ["opt_out", "unset", "subscriber"]]

      assert ["category_not_found", nil, nil] =
               set(s.recipient, "category_channel", "missing", "push", "opt_out")
    end

    test "PC-6: the last open channel of a locked category cannot be closed" do
      s = scenario!()
      ["created", _, 1] = category("billing", "transactional", locked: true)
      ["created", _, 1] = category("feed", "social")

      for channel <- ~w(push email sms) do
        assert ["set", _, 1] = set(s.recipient, "category_channel", "billing", channel, "opt_out")
      end

      assert ["last_channel", nil, nil] =
               set(s.recipient, "category_channel", "billing", "in_app", "opt_out")

      assert ["last_channel", nil, nil] = set(s.recipient, "channel", nil, "in_app", "opt_out")
      assert one("SELECT count(*) FROM relay.preferences WHERE channel = 'in_app'") == 0
      assert ["set", _, 1] = set(s.recipient, "category_channel", "feed", "in_app", "opt_out")
    end

    test "PC-12: every category and channel cell has a value, an effective state and a source" do
      s = scenario!()
      ["created", _, 1] = category("feed", "social", defaults: %{"email" => "on"})
      ["created", _, 1] = category("alerts", "security")
      ["set", _, 1] = set(s.recipient, "category_channel", "feed", "push", "opt_out")

      found = rows("SELECT * FROM relay_fn.preference_cells($1)", [s.recipient])

      cells =
        for [key, _class, _locked, channel, value, effective, source] <- found,
            into: %{},
            do: {{key, channel}, {value, effective, source}}

      assert cells[{"feed", "push"}] == {"opt_out", false, "user"}
      assert cells[{"feed", "email"}] == {"unset", true, "category_default"}
      assert cells[{"feed", "sms"}] == {"unset", false, "class_default"}
      assert cells[{"alerts", "push"}] == {"unset", true, "locked"}
      assert cells[{"alerts", "whatsapp"}] == {"unset", false, "class_default"}
      assert map_size(cells) == 10
    end

    test "PC-45, PC-17: the profile is written by the subscriber or Access and validated" do
      s = scenario!()
      ["created", _, 1] = category("feed", "social")
      ["created", _, 1] = category("orders", "transactional")
      quiet = [%{"day" => "mon", "start" => "22:00", "end" => "07:00"}]
      broken = [%{"day" => "mon"}]

      assert profile(s.recipient, quiet, false, %{}, "tenant") == ["writer_forbidden", nil]
      assert profile(s.recipient, broken, false, %{}, "subscriber") == ["invalid_profile", nil]

      assert profile(s.recipient, quiet, false, %{"orders" => "digest"}, "subscriber") ==
               ["digest_not_allowed", nil]

      assert profile(s.recipient, quiet, true, %{"feed" => "digest"}, "subscriber") ==
               ["created", 1]

      assert profile(s.recipient, quiet, true, %{"feed" => "digest"}, "access", 1) ==
               ["unchanged", 1]

      assert profile(s.recipient, [], true, %{}, "subscriber", 1) == ["updated", 2]
    end
  end

  describe "PC-59 (1) consent copy" do
    test "PC-20: an active consent needs evidence under the subject's consent key" do
      s = scenario!()

      assert ["evidence_required", nil] = consent(s.recipient, "active", 1, evidence: false)
      key = evidence_key(s.recipient)
      assert ["recorded", _] = consent(s.recipient, "active", 1, key: key)
      assert ["evidence_key_invalid", nil] = consent(s.recipient, "active", 2, key: id())
    end

    test "E-80: an older or repeated sequence is never applied" do
      s = scenario!()
      key = evidence_key(s.recipient)

      assert ["recorded", first] = consent(s.recipient, "active", 5, key: key)
      assert ["duplicate", ^first] = consent(s.recipient, "revoked", 5)
      assert ["stale", ^first] = consent(s.recipient, "revoked", 4)
      assert ["recorded", _] = consent(s.recipient, "revoked", 6)

      assert error_message("UPDATE relay.consents SET status = 'active'") =~ "permission denied"
    end

    test "PC-21: the current state is the newest per source and any revoked source wins" do
      s = scenario!()
      key = evidence_key(s.recipient)
      brand = subtenant!()

      ["recorded", _] = consent(s.recipient, "active", 1, key: key)
      ["recorded", revoked] = consent(s.recipient, "revoked", 1, source: "relay_sms_stop")
      ["recorded", _] = consent(s.recipient, "active", 2, key: key)
      ["recorded", _] = consent(s.recipient, "none", 1, channel: "sms")
      ["recorded", branded] = consent(s.recipient, "active", 3, key: key, brand: brand)

      found = rows("SELECT * FROM relay_fn.consent_current($1)", [s.recipient])

      current =
        for [brand_id, channel, status, consent_id | _] <- found,
            into: %{},
            do: {{brand_id, channel}, {status, consent_id}}

      assert current[{nil, "email"}] == {"revoked", revoked}
      assert {"none", _} = current[{nil, "sms"}]
      assert current[{brand, "email"}] == {"active", branded}
    end
  end

  describe "PC-59 (2) suppressions" do
    test "CH-40: a permanent reason never expires, a soft bounce always does" do
      s = scenario!()
      target = digest()
      later = DateTime.add(DateTime.utc_now(), 72 * 3600)

      assert ["invalid_expiry", nil] = suppress(target, s.bidx_key, "hard_bounce", later)
      assert ["invalid_expiry", nil] = suppress(target, s.bidx_key, "soft_bounce")
      assert ["added", hard] = suppress(target, s.bidx_key, "hard_bounce")
      assert ["exists", ^hard] = suppress(target, s.bidx_key, "hard_bounce")
      assert ["added", soft] = suppress(target, s.bidx_key, "soft_bounce", later)
      assert ["key_not_found", nil] = suppress(target, id(), "manual")

      assert [[^hard, "hard_bounce", nil], [^soft, "soft_bounce", %DateTime{}]] =
               rows(@match, ["email", [target]])

      assert rows(@match, ["sms", [target]]) == []
    end

    test "PC-59 (2): a lift writes lifted_at; hard bounce lifts need an operator with step-up" do
      s = scenario!()

      ["added", hard] = suppress(digest(), s.bidx_key, "hard_bounce")
      ["added", manual] = suppress(digest(), s.bidx_key, "manual")

      assert lift(hard, "tenant") == "lift_forbidden"
      assert lift(hard, "operator") == "step_up_required"
      assert lift(hard, "operator", "stepup_1") == "lifted"
      assert lift(hard, "operator", "stepup_1") == "already_lifted"
      assert lift(manual, "tenant") == "lifted"
      assert lift(id(), "tenant") == "not_found"

      assert [_, _] = audit("suppression.lifted")
      assert [_] = audit("suppression.added")
      assert one("SELECT count(*) FROM relay.suppressions WHERE lifted_at IS NOT NULL") == 2
    end

    test "OP-20: a subject erasure leaves the keyed suppression digest in place" do
      s = scenario!()
      target = digest()
      ["added", suppression] = suppress(target, s.bidx_key, "complaint")
      destroy = ~w(recipient_profile preference)

      assert ["erased", _] = row(@erase, [s.recipient, destroy, [], digest() | actor()])
      assert [[^suppression, "complaint", nil]] = rows(@match, ["email", [target]])
    end
  end
end
