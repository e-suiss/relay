defmodule Relay.Sql.TemplatesTest do
  use Relay.SqlCase, async: false

  @category "SELECT * FROM relay_fn.category_create($1, $2, $3, $4, false, true, '{}', NULL, NULL, NULL, NULL, false, $5, $6, $7, $8, $9)"
  @create "SELECT * FROM relay_fn.template_create($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)"
  @update "SELECT * FROM relay_fn.template_update($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)"
  @draft "SELECT * FROM relay_fn.template_draft_put($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)"
  @publish "SELECT * FROM relay_fn.template_publish($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)"
  @rollback "SELECT * FROM relay_fn.template_rollback($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)"
  @archive "SELECT * FROM relay_fn.template_archive($1, $2, $3, $4, $5, $6, $7, $8, $9)"
  @version_archive "SELECT relay_fn.template_version_archive($1, $2, $3, $4, $5, $6, $7, $8, $9)"
  @live "SELECT key, owner, version_no, layout_version_id, partial_version_ids, source, rule_id FROM relay_fn.template_live($1, $2)"
  @brand "SELECT field, value, source FROM relay_fn.brand_resolve($1, $2)"
  @setting "SELECT * FROM relay_fn.setting_set($1, $2, $3, NULL, $4, $5, $6, $7, $8)"
  @asset_create "SELECT * FROM relay_fn.KIND_create($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)"
  @asset_publish "SELECT * FROM relay_fn.KIND_publish($1, $2, NULL, '[]', false, NULL, NULL, $3, $4, $5, $6, $7)"
  @asset_archive "SELECT * FROM relay_fn.KIND_archive($1, $2, NULL, $3, $4, $5, $6, $7)"
  @subtenant "SELECT * FROM relay_fn.subtenant_upsert($1, $2, 'Brand', $3, $4, $5, $6, $7)"
  @subject_key "SELECT * FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)"
  @wrap "SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1 LIMIT 1"
  @otp "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, NULL, $3, 'security', 'otp_oob', 'system', NULL, NULL, $4, false, NULL)"
  @pin "SELECT relay_fn.delivery_plan_pin($1, $2, $3, $4, $5, $6)"
  @policy "SELECT * FROM relay_fn.delivery_render_policy($1)"
  @record "SELECT relay_fn.delivery_render_record($1, $2, $3, $4, $5)"
  @fail "SELECT relay_fn.delivery_render_fail($1, $2, $3)"
  @audit "SELECT action, target_id FROM relay_fn.audit_query($1, $2, $3, NULL, 10, $4, $5, $6, $7, $8)"
  @templates "SELECT key, owner, message_class::text, template_type FROM relay.templates ORDER BY key"
  @versions "SELECT version_no, state, previous_version_no FROM relay.template_versions WHERE template_id = $1 ORDER BY version_no"
  @accepted "SELECT warnings_accepted, warnings_accepted_by_ref, findings FROM relay.template_versions WHERE id = $1"
  @plan "SELECT locale, locale_fallback, render_count FROM relay.delivery_render_plans WHERE delivery_id = $1"
  @rendered "SELECT render_digest, render_measures, render_count FROM relay.delivery_render_plans WHERE delivery_id = $1"
  @snapshot "SELECT retention_class::text, content_digest, content_ct, content_key_id, digest_reason, template_version_id FROM relay.render_snapshots WHERE delivery_id = $1"
  @failure "SELECT failure_kind, failure_class, failure_reason, failure_rule_id FROM relay.deliveries WHERE id = $1"
  @ledger "SELECT detail FROM relay.delivery_events WHERE delivery_id = $1 AND event_type = 'delivery.render_failed'"
  @outbox "SELECT payload FROM relay.outbox_events WHERE event_type = 'notification.render_failed' AND stream_key = $1"
  @reclass "UPDATE relay.templates SET message_class = 'marketing', template_type = 'marketing'"
  @variables %{"always" => ["order.id"], "conditional" => []}
  @measures %{"sms" => %{"tr" => %{"segments" => 1}}}

  defp category!(key, class) do
    ["created", id, 1] = row(@category, [id(), key, "Name of " <> key, class, digest() | actor()])
    id
  end

  defp definition(opts \\ []) do
    body = Keyword.get(opts, :body, "Siparişiniz {{ order.id }}")

    %{
      "default_locale" => "tr",
      "sensitivity" => Keyword.get(opts, :sensitivity, "personal"),
      "layout" => opts[:layout],
      "partials" => Keyword.get(opts, :partials, []),
      "producer_brand" => opts[:producer_brand],
      "cells" => Keyword.get(opts, :cells, %{"sms" => %{"tr" => %{"body" => body}}})
    }
  end

  defp create(key, category, opts \\ []) do
    row(@create, [
      id(),
      id(),
      key,
      opts[:subtenant],
      opts[:product],
      "Template " <> key,
      category,
      Keyword.get(opts, :definition, definition()),
      digest() | actor()
    ])
  end

  defp update(key, category, version) do
    row(@update, [key, nil, nil, "Order", category, version, digest() | actor()])
  end

  defp draft(key, definition, opts \\ []) do
    row(@draft, [
      id(),
      key,
      opts[:subtenant],
      opts[:product],
      definition,
      opts[:version],
      digest() | actor()
    ])
  end

  defp publish(key, opts \\ []) do
    row(@publish, [
      key,
      opts[:subtenant],
      opts[:product],
      opts[:checksum],
      @variables,
      @measures,
      Keyword.get(opts, :findings, []),
      Keyword.get(opts, :accept, false),
      opts[:diff],
      opts[:version],
      digest() | actor()
    ])
  end

  defp rollback(key, version_no, opts \\ []) do
    row(@rollback, [key, nil, opts[:product], version_no, nil, digest() | actor()])
  end

  defp archive(key, opts \\ []) do
    row(@archive, [key, nil, opts[:product], nil, digest() | actor()])
  end

  defp version_archive(key, version_no) do
    one(@version_archive, [key, nil, nil, version_no, digest() | actor()])
  end

  defp live(keys, subtenant \\ nil), do: rows(@live, [keys, subtenant])

  defp asset!(kind, key, content) do
    sql = String.replace(@asset_create, "KIND", kind)

    ["created", _asset_id, version_id, 1] =
      row(sql, [id(), id(), key, nil, "Asset " <> key, content, digest() | actor()])

    version_id
  end

  defp asset_publish(kind, key) do
    row(String.replace(@asset_publish, "KIND", kind), [key, nil, digest() | actor()])
  end

  defp asset_archive(kind, key) do
    row(String.replace(@asset_archive, "KIND", kind), [key, nil, digest() | actor()])
  end

  defp subtenant! do
    org = "org_" <> Base.encode16(digest())
    ["created", subtenant, _] = row(@subtenant, [id(), org, digest() | actor()])
    subtenant
  end

  defp setting!(subtenant, key, value) do
    [result, _version] = row(@setting, [subtenant, key, value, digest() | actor()])
    assert result in ["created", "updated"]
  end

  defp audited(action) do
    now = DateTime.utc_now()
    params = [DateTime.add(now, -3600), DateTime.add(now, 3600), action, digest() | actor()]
    for [^action, target] <- rows(@audit, params), do: target
  end

  defp published_version!(key, category, opts \\ []) do
    ["created", _template, _draft, 1] = create(key, category, opts)
    ["published", version_id, 1, 2] = publish(key, opts)
    version_id
  end

  defp brand(subtenant, version_id) do
    for [field, value, source] <- rows(@brand, [subtenant, version_id]),
        into: %{},
        do: {field, {value, source}}
  end

  defp delivery_with_plan!(notification) do
    category!("orders", "transactional")
    version_id = published_version!("order-shipped", "orders")
    delivery = delivery!(notification)
    assert one(@pin, [delivery, version_id, nil, [], "tr", false]) == "pinned"
    {delivery, version_id}
  end

  defp content_key!(recipient, class) do
    wrap = one(@wrap, [recipient])
    ["created", key] = row(@subject_key, [id(), recipient, class, digest(), wrap])
    key
  end

  describe "TP-48 TP-1 INV-21 templates" do
    test "TP-48, TP-1: a template is unique by key and level, takes its category's class and is audited" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      category!("offers", "marketing")

      assert ["created", template_id, _draft, 1] = create("order-shipped", "orders")
      assert ["key_conflict", ^template_id, nil, 1] = create("order-shipped", "offers")
      assert ["created", _other, _, 1] = create("offer-weekly", "offers")
      assert ["category_not_found", nil, nil, nil] = create("x-y", "missing")

      assert rows(@templates) == [
               ["offer-weekly", "tenant", "marketing", "marketing"],
               ["order-shipped", "tenant", "transactional", "transactional"]
             ]

      assert Relay.Id.to_string(template_id) in audited("template.created")
      assert error_message("UPDATE relay.templates SET name = 'x'") =~ "permission denied"
    end

    test "INV-21, TP-1: the message class of a template does not change after its first publication" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      category!("receipts", "transactional")
      category!("offers", "marketing")

      ["created", _, _, 1] = create("order-shipped", "orders")
      assert ["updated", 2] = update("order-shipped", "offers", nil)
      assert one("SELECT template_type FROM relay.templates") == "marketing"
      assert ["updated", 3] = update("order-shipped", "orders", nil)
      assert ["published", _, 1, 4] = publish("order-shipped")

      assert ["class_locked", 4] = update("order-shipped", "offers", nil)
      assert ["updated", 5] = update("order-shipped", "receipts", 4)
      assert ["version_conflict", 5] = update("order-shipped", "orders", 4)
    end
  end

  describe "TP-31 TP-32 versions and the publication gate" do
    test "TP-31: versions are numbered monotonically and publication moves the live pointer" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      second = definition(body: "Kargonuz {{ order.id }} yolda")

      ["created", template_id, first_draft, 1] = create("order-shipped", "orders")
      assert ["published", ^first_draft, 1, 2] = publish("order-shipped")
      assert ["no_draft", nil, nil, 2] = publish("order-shipped")
      assert ["created", second_draft, 3] = draft("order-shipped", second)
      assert ["unchanged", ^second_draft, 3] = draft("order-shipped", second)
      assert ["published", ^second_draft, 2, 4] = publish("order-shipped", diff: %{"sms" => 1})

      assert rows(@versions, [template_id]) == [[1, "published", nil], [2, "published", 1]]
      assert one("SELECT live_version_no FROM relay.templates") == 2
      assert Relay.Id.to_string(template_id) in audited("template.published")
    end

    test "TP-31: the same content is never published twice" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      ["created", _, _, 1] = create("order-shipped", "orders")
      ["published", _, 1, 2] = publish("order-shipped")

      assert ["created", _draft, 3] = draft("order-shipped", definition())
      assert ["duplicate", _, 1, 3] = publish("order-shipped")
    end

    test "TP-32: a hard finding refuses publication and warnings publish only when accepted" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      ["created", _, draft_id, 1] = create("order-shipped", "orders")
      warning = %{"check" => "sms_segments", "level" => "warning", "message" => "two segments"}
      hard = %{"check" => "plain_text_missing", "level" => "hard", "message" => "missing"}
      accepted = [findings: [warning], accept: true]

      assert ["gate_failed", ^draft_id, nil, 1] = publish("order-shipped", findings: [hard])
      assert ["warnings_unaccepted", _, nil, 1] = publish("order-shipped", findings: [warning])
      changed = publish("order-shipped", [checksum: digest()] ++ accepted)
      assert ["draft_changed", ^draft_id, nil, 1] = changed
      assert ["published", ^draft_id, 1, 2] = publish("order-shipped", accepted)
      assert rows(@accepted, [draft_id]) == [[true, "acc_op_1", [warning]]]
    end

    test "TP-30: a machine translated cell is not published until a person approves it" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      cell = %{"body" => "Your order {{ order.id }}", "machine_translated" => true}
      cells = %{"sms" => %{"tr" => %{"body" => "Siparişiniz"}, "en" => cell}}
      approved = put_in(cells, ["sms", "en", "translation_approved_by"], "acc_user_1")

      machine = definition(cells: cells)

      ["created", _, _, 1] = create("order-shipped", "orders", definition: machine)
      assert ["translation_unapproved", _, nil, 1] = publish("order-shipped")
      assert ["replaced", _, 2] = draft("order-shipped", definition(cells: approved))
      assert ["published", _, 1, 3] = publish("order-shipped")
    end

    test "TP-31: a published version never changes, even for the table owner, and is never deleted" do
      admin = connect(:admin)

      rolled_back(admin, fn ->
        tenant = tenant!()
        ctx(tenant)
        category!("orders", "transactional")
        version = published_version!("order-shipped", "orders")
        archive = "UPDATE relay.template_versions SET state = 'archived', archived_at = now()"
        restore = "UPDATE relay.template_versions SET state = 'published', archived_at = NULL"

        for statement <- [
              "UPDATE relay.template_versions SET cells = '{}' WHERE id = $1",
              "UPDATE relay.template_versions SET version_no = NULL WHERE id = $1",
              "DELETE FROM relay.template_versions WHERE id = $1"
            ] do
          assert sql_error(statement, [version]).postgres.message == "invariant_violation"
        end

        assert rows(archive <> " WHERE id = $1", [version]) == []
        message = sql_error(restore <> " WHERE id = $1", [version]).postgres.message
        assert message == "invariant_violation"
      end)

      GenServer.stop(admin)
    end

    test "INV-21: the class of a published template cannot be rewritten directly" do
      admin = connect(:admin)

      rolled_back(admin, fn ->
        tenant = tenant!()
        ctx(tenant)
        category!("orders", "transactional")
        published_version!("order-shipped", "orders")
        assert sql_error(@reclass).postgres.message == "invariant_violation"
      end)

      GenServer.stop(admin)
    end

    test "TP-31: rollback moves the live pointer to a published version and creates no version" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      ["created", template_id, first, 1] = create("order-shipped", "orders")
      ["published", ^first, 1, 2] = publish("order-shipped")
      ["created", second, 3] = draft("order-shipped", definition(body: "İkinci {{ order.id }}"))
      ["published", ^second, 2, 4] = publish("order-shipped")

      assert ["rolled_back", ^first, 5] = rollback("order-shipped", 1)
      assert ["unchanged", ^first, 5] = rollback("order-shipped", 1)
      assert ["version_not_found", nil, 5] = rollback("order-shipped", 9)
      assert one("SELECT live_version_no FROM relay.templates") == 1
      assert one("SELECT count(*) FROM relay.template_versions") == 2

      assert version_archive("order-shipped", 1) == "live_version"
      assert version_archive("order-shipped", 2) == "archived"
      assert version_archive("order-shipped", 2) == "already_archived"
      assert ["version_archived", ^second, 5] = rollback("order-shipped", 2)
      assert Relay.Id.to_string(template_id) in audited("template.rolled_back")
    end
  end

  describe "TP-36 TP-51 the live set and inheritance" do
    test "TP-51: the live set reports template.not_published and template.archived" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      ["created", _, _, 1] = create("draft-only", "orders")
      published_version!("order-shipped", "orders")
      published_version!("order-old", "orders")
      assert ["archived", _] = archive("order-old")
      assert ["already_archived", _] = archive("order-old")

      assert live(["order-shipped", "draft-only", "order-old", "missing"]) == [
               ["order-shipped", "tenant", 1, nil, [], "tenant", nil],
               ["draft-only", "tenant", nil, nil, [], "tenant", "template.not_published"],
               ["order-old", "tenant", nil, nil, [], "tenant", "template.archived"],
               ["missing", nil, nil, nil, [], nil, "template.not_published"]
             ]
    end

    test "TP-36: a subtenant's own template overrides the tenant's, which it inherits otherwise" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      subtenant = subtenant!()
      published_version!("order-shipped", "orders")

      assert [[_, "tenant", 1, _, _, "tenant", nil]] = live(["order-shipped"], subtenant)
      assert ["created", _, _, 1] = create("order-shipped", "orders", subtenant: subtenant)
      assert [[_, "tenant", 1, _, _, "tenant", nil]] = live(["order-shipped"], subtenant)
      assert ["published", _, 1, 2] = publish("order-shipped", subtenant: subtenant)

      assert [["order-shipped", "subtenant", 1, _, _, "subtenant", nil]] =
               live(["order-shipped"], subtenant)

      assert [["order-shipped", "tenant", 1, _, _, "tenant", nil]] = live(["order-shipped"])
    end

    test "TP-36: brand fields of a subtenant fall back to the tenant's" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      subtenant = subtenant!()
      version_id = published_version!("order-shipped", "orders")
      setting!(nil, "brand.sender_name", "Acme")
      setting!(nil, "brand.logo_url", "https://cdn.example.com/acme.png")
      setting!(subtenant, "brand.sender_name", "Acme TR")

      fields = brand(subtenant, version_id)
      assert fields["sender_name"] == {"Acme TR", "subtenant"}
      assert fields["logo_url"] == {"https://cdn.example.com/acme.png", "tenant"}
      assert fields["footer"] == {nil, "none"}
      assert brand(nil, version_id)["sender_name"] == {"Acme", "tenant"}
    end
  end

  describe "TP-52 TP-37 producer templates" do
    test "TP-52: a producer template is protected and the tenant overrides only four brand fields" do
      tenant = tenant!()
      ctx(tenant)
      category!("codes", "transactional")
      own = %{"sender_name" => "Access", "legal_name" => "Suiss", "footer" => "F"}
      producer = definition(producer_brand: own)
      tenant_text = definition(body: "Tenant text")

      opts = [product: "access", definition: producer]
      assert ["created", _, _, 1] = create("access-otp", "codes", opts)
      assert ["protected", nil, 1] = draft("access-otp", tenant_text)
      assert ["protected", nil, nil, 1] = publish("access-otp")
      assert ["protected", _] = archive("access-otp")
      assert ["protected", nil, 1] = rollback("access-otp", 1)
      assert ["protected", nil, 1] = draft("access-otp", producer, product: "other")
      assert ["published", version_id, 1, 2] = publish("access-otp", product: "access")
      assert one("SELECT owner FROM relay.templates") == "producer"

      setting!(nil, "brand.sender_name", "Tenant")
      setting!(nil, "brand.legal_name", "Tenant Ltd")
      setting!(nil, "brand.primary_color", "#112233")

      fields = brand(nil, version_id)
      assert fields["sender_name"] == {"Tenant", "tenant"}
      assert fields["legal_name"] == {"Suiss", "producer"}
      assert fields["footer"] == {"F", "producer"}
      assert fields["primary_color"] == {"#112233", "tenant"}

      params = [id(), id(), "t-b", nil, nil, "T", "codes", producer, digest() | actor()]
      assert sql_error(@create, params).postgres.message == "invalid_argument"
    end
  end

  describe "TP-35 layouts and partials" do
    test "TP-35: layouts and partials are versioned, referenced by key and resolved at their live version" do
      tenant = tenant!()
      ctx(tenant)
      category!("orders", "transactional")
      with_assets = definition(layout: "main", partials: ["legal"])

      assert ["layout_not_found", nil, nil, nil] =
               create("order-shipped", "orders", definition: definition(layout: "main"))

      layout = asset!("layout", "main", %{"mjml" => "<mjml/>"})
      partial = asset!("partial", "legal", %{"bodies" => %{"tr" => "Yasal"}})

      assert ["created", _, _, 1] = create("order-shipped", "orders", definition: with_assets)
      assert ["layout_not_published", _, nil, 1] = publish("order-shipped")
      assert ["published", ^layout, 1, 2] = asset_publish("layout", "main")
      assert ["partial_not_published", _, nil, 1] = publish("order-shipped")
      assert ["published", ^partial, 1, 2] = asset_publish("partial", "legal")
      assert ["no_draft", nil, nil, 2] = asset_publish("partial", "legal")
      assert ["published", _, 1, 2] = publish("order-shipped")

      assert [["order-shipped", "tenant", 1, ^layout, [^partial], "tenant", nil]] =
               live(["order-shipped"])

      assert ["in_use", 2] = asset_archive("layout", "main")
      assert ["in_use", 2] = asset_archive("partial", "legal")
    end
  end

  describe "TP-50 TP-40 TP-41 render plan, snapshot and failure" do
    test "TP-50: the render plan is pinned once, only to published versions" do
      s = scenario!()
      category!("orders", "transactional")
      ["created", _, version, 1] = create("order-shipped", "orders")
      delivery = delivery!(s.notification)

      assert one(@pin, [delivery, version, nil, [], "tr", false]) == "version_not_published"
      assert one(@pin, [id(), version, nil, [], "tr", false]) == "delivery_not_found"
      ["published", ^version, 1, 2] = publish("order-shipped")
      assert one(@pin, [delivery, version, nil, [id()], "tr", false]) == "partial_not_published"
      assert one(@pin, [delivery, version, id(), [], "tr", false]) == "layout_not_published"
      assert one(@pin, [delivery, version, nil, [], "tr-TR", true]) == "pinned"
      assert one(@pin, [delivery, version, nil, [], "en", false]) == "exists"
      assert rows(@plan, [delivery]) == [["tr-TR", true, 0]]

      assert error_message("UPDATE relay.delivery_render_plans SET locale = 'en'") =~
               "permission denied"
    end

    test "TP-40, TP-50: the first render seals the content under the subject key and retries compare digests" do
      s = scenario!()
      {delivery, version_id} = delivery_with_plan!(s.notification)
      key = content_key!(s.recipient, "notification_content")
      other = content_key!(s.recipient, "commercial_message")
      measures = %{"characters" => 24, "segments" => 1, "encoding" => "GSM7_TR"}
      output = digest()
      recipient = s.recipient

      assert [["ok", nil, "notification_content", ^recipient, ^key]] = rows(@policy, [delivery])
      assert one(@record, [delivery, output, measures, nil, nil]) == "content_required"
      assert one(@record, [delivery, output, measures, "sealed", other]) == "key_invalid"
      assert one(@record, [delivery, output, measures, "sealed", key]) == "recorded"
      assert one(@record, [delivery, output, measures, nil, nil]) == "matched"
      assert one(@record, [delivery, digest(), measures, nil, nil]) == "digest_mismatch"

      assert rows(@snapshot, [delivery]) == [
               ["notification_content", output, "sealed", key, nil, version_id]
             ]

      assert rows(@rendered, [delivery]) == [[output, measures, 3]]

      assert error_message("UPDATE relay.render_snapshots SET content_ct = NULL") =~
               "permission denied"
    end

    test "TP-40, INV-26: an OTP render keeps only its digest and the template version" do
      s = scenario!()
      expires_at = DateTime.add(DateTime.utc_now(), 300)
      dedup = "otp:" <> Base.encode16(digest())
      ["created", notification] = row(@otp, [id(), s.recipient, dedup, expires_at])
      {delivery, version_id} = delivery_with_plan!(notification)
      output = digest()

      assert [["ok", "security_subtype", _, _, nil]] = rows(@policy, [delivery])
      assert one(@record, [delivery, output, %{}, "plain", id()]) == "content_not_allowed"
      assert one(@record, [delivery, output, %{}, nil, nil]) == "recorded"

      assert rows(@snapshot, [delivery]) == [
               ["notification_content", output, nil, nil, "security_subtype", version_id]
             ]
    end

    test "TP-41, INV-46: a render failure fails the delivery with its ledger event and outbox event at once" do
      s = scenario!()
      {delivery, _version_id} = delivery_with_plan!(s.notification)
      template = %{"key" => "order-shipped", "version" => 1}

      missing = %{"variables" => ["order.id"]}
      assert one(@fail, [delivery, "missing_variable", missing]) == "failed"
      assert one(@fail, [delivery, "render_timeout", nil]) == "already_terminal"
      assert one(@fail, [id(), "render_timeout", nil]) == "not_found"

      assert rows(@failure, [delivery]) == [
               ["failed", "permanent_content", "missing_variable", nil]
             ]

      assert [[detail]] = rows(@ledger, [delivery])
      assert detail["failure_reason"] == "missing_variable"
      assert detail["template"] == template

      assert [[payload]] = rows(@outbox, ["delivery:" <> Ecto.UUID.load!(delivery)])
      assert payload["failure_reason"] == "missing_variable"
      assert payload["channel"] == "sms"
      assert payload["template"] == template

      assert sql_error(@fail, [delivery, "boom", nil]).postgres.message == "invalid_argument"
    end
  end
end
