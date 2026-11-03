defmodule RelayWeb.Api.TemplateRenderTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Templates.Live
  alias Relay.TemplateStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @actor ["operator", "acc_op_1", "acc_op_1", nil]
  @setting "SELECT * FROM relay_fn.setting_set($1, $2, $3, NULL, $4, $5, $6, $7, $8)"
  @plan "SELECT template_version_id, layout_version_id, partial_version_ids, locale, locale_fallback, render_digest, render_count FROM relay.delivery_render_plans WHERE delivery_id = $1"
  @snapshots "SELECT content_digest, content_ct, content_key_id, digest_reason, template_version_id, retention_class::text FROM relay.render_snapshots WHERE delivery_id = $1"
  @failure "SELECT failure_kind::text, failure_class::text, failure_reason FROM relay.deliveries WHERE id = $1"
  @render_failed "SELECT detail FROM relay.delivery_events WHERE delivery_id = $1 AND event_type = 'delivery.render_failed'"
  @outbox "SELECT payload FROM relay.outbox_events WHERE stream_key = $1 AND event_type = $2 ORDER BY id"
  @skipped "SELECT detail FROM relay.delivery_events WHERE delivery_id = $1 AND event_type = 'delivery.skipped'"
  @live "SELECT t.live_version_id FROM relay.templates t WHERE t.key = $1 AND t.subtenant_id IS NOT DISTINCT FROM $2"

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp template!(ctx, cells, opts \\ []) do
    :ok = F.category!(ctx.token, "orders")
    definition = F.template_definition(cells, opts)
    :ok = F.template!(ctx.scope, "order-shipped", "orders", definition: definition)
  end

  defp workflow!(ctx, channels, opts \\ []) do
    F.workflow!(ctx.scope, ctx.token, "order-shipped", [channels: channels] ++ opts)
  end

  defp subscriber!(token, fields \\ %{}) do
    external_id = "user-" <> TenantFixture.random()
    body = Map.merge(%{"external_id" => external_id, "email" => "ayse@example.com"}, fields)
    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    external_id
  end

  defp send!(token, to, extra \\ %{}) do
    base = %{"workflow" => "order-shipped", "to" => [to], "data" => %{"order" => "A-1"}}
    body = Map.merge(base, extra)

    F.body(F.request(:post, "/v1/events", token, body), 202)
  end

  defp deliveries(token, accepted) do
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    Map.new(F.body(F.request(:get, path, token), 200)["data"], &{&1["channel"], &1})
  end

  defp delivery!(token, to, extra \\ %{}) do
    [delivery] = Map.values(deliveries(token, send!(token, to, extra)))
    delivery
  end

  defp internal(%{"id" => id}) do
    {:ok, delivery_id} = Relay.ExternalId.decode(id, ["dlv"])
    delivery_id
  end

  defp plan(scope, delivery) do
    case sql!(scope, @plan, [internal(delivery)]) do
      [[version, layout, partials, locale, fallback, digest, count]] ->
        %{
          version: version,
          layout: layout,
          partials: partials,
          locale: locale,
          fallback: fallback,
          digest: digest,
          count: count
        }

      [] ->
        nil
    end
  end

  defp snapshots(scope, delivery), do: sql!(scope, @snapshots, [internal(delivery)])

  defp live_version(scope, subtenant_id \\ nil) do
    [[id]] = sql!(scope, @live, ["order-shipped", subtenant_id])
    id
  end

  defp outbox(scope, delivery, type) do
    stream = "delivery:" <> Relay.Id.to_string(internal(delivery))
    for [payload] <- sql!(scope, @outbox, [stream, type]), do: payload
  end

  defp run!(scope, delivery) do
    id = Relay.Id.to_string(internal(delivery))
    args = Map.put(Relay.Scope.to_job_args(scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
  end

  defp content(scope, recipient_id, [_digest, ct, _key, nil, _version, class]) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: String.to_existing_atom(class),
      table: "render_snapshots",
      column: "content_ct"
    }

    {:ok, plain} = Relay.Tenancy.decrypt_field(field, ct)
    plain = Relay.Redacted.expose(plain)
    {plain, Jason.decode!(plain)}
  end

  defp recipient(accepted) do
    [%{"recipient_id" => id}] = accepted["notifications"]
    {:ok, recipient_id} = Relay.ExternalId.decode(id, ["sub"])
    recipient_id
  end

  defp setting!(scope, subtenant, key, value) do
    [[result, _version]] =
      sql!(scope, @setting, [subtenant, key, value, TenantFixture.digest() | @actor])

    assert result in ["created", "updated"]
  end

  defp attach(event) do
    ref = make_ref()
    pid = self()
    handler = "template-render-test-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, meta, _config -> send(pid, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp with_sandbox(nil, fun), do: fun.()

  defp with_sandbox(options, fun) do
    previous = Application.get_env(:relay, Relay.Templates.Sandbox)
    Application.put_env(:relay, Relay.Templates.Sandbox, options)

    try do
      fun.()
    after
      Application.put_env(:relay, Relay.Templates.Sandbox, previous)
    end
  end

  describe "TP-50 pinned plan at acceptance" do
    test "TP-50, INV-48: acceptance pins the live template version and the recipient's locale",
         ctx do
      workflow!(ctx, ["email"])
      delivery = delivery!(ctx.token, subscriber!(ctx.token))

      assert delivery["status"] == "queued"
      plan = plan(ctx.scope, delivery)
      assert plan.version == live_version(ctx.scope)
      assert %{locale: "tr", fallback: false, layout: nil, partials: []} = plan
      assert %{digest: nil, count: 0} = plan
    end

    test "TP-36: a sub-tenant's own template is pinned over the tenant's, others inherit", ctx do
      workflow!(ctx, ["sms"])
      subtenant = TenantFixture.subtenant!(ctx.scope)

      own = F.template_definition(%{"sms" => %{"body" => "Şube: {{ order }}"}})
      F.template!(ctx.scope, "order-shipped", "orders", definition: own, subtenant_id: subtenant)
      branch = %{"tenant" => Relay.ExternalId.encode("stn", subtenant)}

      inherited = delivery!(ctx.token, subscriber!(ctx.token, %{"phone" => "+905551112233"}))
      own_delivery = delivery!(ctx.token, subscriber!(ctx.token), branch)

      assert plan(ctx.scope, inherited).version == live_version(ctx.scope)
      assert plan(ctx.scope, own_delivery).version == live_version(ctx.scope, subtenant)
      refute live_version(ctx.scope) == live_version(ctx.scope, subtenant)

      other = TenantFixture.subtenant!(ctx.scope)
      other_branch = %{"tenant" => Relay.ExternalId.encode("stn", other)}
      fallback = delivery!(ctx.token, subscriber!(ctx.token), other_branch)
      assert plan(ctx.scope, fallback).version == live_version(ctx.scope)
    end

    test "WF-16, TP-11, TP-51: a channel without a variant is skipped and the next one is sent",
         ctx do
      template!(ctx, %{"sms" => %{"body" => "Kargoda {{ order }}"}})
      workflow!(ctx, ["push", "sms"])
      ref = attach([:relay, :policy, :decision])

      accepted = send!(ctx.token, subscriber!(ctx.token, %{"phone" => "+905551112233"}))
      by_channel = deliveries(ctx.token, accepted)

      push = by_channel["push"]
      assert %{"status" => "skipped", "reason" => "no_channel_variant"} = push
      assert push["rule_id"] == "template.variant_missing"
      assert plan(ctx.scope, push) == nil
      assert F.delivery_jobs(push["id"]) == []
      assert_receive {^ref, _, %{decision: :skip, reason: "no_channel_variant"}}

      [skipped] = outbox(ctx.scope, push, "notification.suppressed")
      assert skipped["rule_id"] == "template.variant_missing"
      assert skipped["channel"] == "push"

      [[detail]] = sql!(ctx.scope, @skipped, [internal(push)])

      assert %{"template" => %{"key" => "order-shipped", "version" => 1}} = detail
      assert detail["channel"] == "push"

      sms = by_channel["sms"]
      assert sms["status"] == "queued"
      assert plan(ctx.scope, sms).locale == "tr"
      assert [_job] = F.delivery_jobs(sms["id"])
    end

    test "TP-26: a locale without a cell falls back to the tenant default and is counted", ctx do
      workflow!(ctx, ["email"])
      ref = attach([:relay, :templates, :locale_missing])

      delivery = delivery!(ctx.token, subscriber!(ctx.token, %{"locale" => "de"}))

      assert delivery["status"] == "queued"
      assert %{locale: "tr", fallback: true} = plan(ctx.scope, delivery)
      assert_receive {^ref, %{count: 1}, %{channel: :email} = meta}
      assert Map.keys(meta) == [:channel]
    end

    test "TP-26, TP-51: no cell in the locale chain skips with template.locale_missing", ctx do
      template!(ctx, %{"email" => %{"en" => email_cell("Shipped")}})
      workflow!(ctx, ["email"])

      delivery = delivery!(ctx.token, subscriber!(ctx.token))

      assert %{"status" => "skipped", "reason" => "template_locale_missing"} = delivery
      assert delivery["rule_id"] == "template.locale_missing"
      assert plan(ctx.scope, delivery) == nil
    end

    test "TP-51: a template without a live version or archived skips with its rule", ctx do
      :ok = F.category!(ctx.token, "orders")
      {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")

      attrs = %{
        id: Relay.Id.generate(),
        version_id: Relay.Id.generate(),
        key: "order-shipped",
        name: "Draft only",
        category: "orders",
        definition: F.template_definition()
      }

      {:ok, {:created, _, _, _}} =
        Repo.in_scope(ctx.scope, fn _status ->
          TemplateStore.template_create(attrs, TenantFixture.digest(), actor)
        end)

      workflow!(ctx, ["email"])
      draft = delivery!(ctx.token, subscriber!(ctx.token))
      assert %{"status" => "skipped", "reason" => "template_unavailable"} = draft
      assert draft["rule_id"] == "template.not_published"

      at = %{key: "order-shipped", subtenant_id: nil, product: nil}
      gate = %{variables: %{}, measures: %{}, findings: [], accept_warnings: false}

      {:ok, {:archived, _}} =
        Repo.in_scope(ctx.scope, fn _status ->
          {:published, _, 1, _} =
            TemplateStore.template_publish(at, gate, nil, TenantFixture.digest(), actor)

          TemplateStore.template_archive(at, nil, TenantFixture.digest(), actor)
        end)

      archived = delivery!(ctx.token, subscriber!(ctx.token))
      assert archived["rule_id"] == "template.archived"
      assert plan(ctx.scope, archived) == nil
    end

    test "PC-58 (8), TP-51: a dry run answers the template rule and pins nothing", ctx do
      scope = ctx.tenant.test
      token = F.token(scope)
      :ok = F.category!(token, "orders")
      cells = F.template_definition(%{"sms" => %{"body" => "Kargoda"}})
      :ok = F.template!(scope, "order-shipped", "orders", definition: cells)
      F.workflow!(scope, token, "order-shipped", channels: ["push", "sms"])
      external_id = subscriber!(token, %{"phone" => "+905551112233"})

      sent = send!(token, external_id, %{"send_mode" => "dry_run"})
      [%{"decisions" => decisions}] = sent["notifications"]
      by_channel = Map.new(decisions, &{&1["channel"], &1})

      assert %{"decision" => "skip", "rule_id" => "template.variant_missing"} = by_channel["push"]
      assert by_channel["push"]["reason"] == "no_channel_variant"
      assert by_channel["sms"]["decision"] == "send"
      assert deliveries(token, sent) == %{}
      assert sql!(scope, "SELECT count(*) FROM relay.delivery_render_plans", []) == [[0]]
    end
  end

  describe "TP-50 render in the send job" do
    test "TP-50, TP-40: the first render records the digest and seals the content snapshot",
         ctx do
      template!(ctx, %{"email" => email_cell("Siparişiniz {{ order }} kargoda")})
      workflow!(ctx, ["email"])
      ref = attach([:relay, :render, :stop])

      accepted = send!(ctx.token, subscriber!(ctx.token))
      delivery = deliveries(ctx.token, accepted)["email"]

      assert run!(ctx.scope, delivery) == {:snooze, 300}
      assert_receive {^ref, %{duration: duration}, %{channel: :email, result: :ok}}
      assert is_integer(duration)

      plan = plan(ctx.scope, delivery)
      assert byte_size(plan.digest) == 32
      assert plan.count == 1

      [[digest, ct, key_id, nil, version, "notification_content"] = row] =
        snapshots(ctx.scope, delivery)

      assert digest == plan.digest
      assert is_binary(ct) and is_binary(key_id)
      assert version == plan.version

      {plain, snapshot} = content(ctx.scope, recipient(accepted), row)
      assert :crypto.hash(:sha256, plain) == digest
      assert snapshot["channel"] == "email"
      assert snapshot["locale"] == "tr"
      assert snapshot["output"]["subject"] == "Siparişiniz A-1 kargoda"
      assert snapshot["output"]["text"] == "Siparişiniz A-1 kargoda"
      assert [_job] = F.delivery_jobs(delivery["id"])
    end

    test "INV-26, TP-40: an OTP render and a retention none render keep the digest only", ctx do
      :ok = F.category!(ctx.token, "login", "security")
      cells = %{"sms" => %{"body" => "Kodunuz {{ order }}"}}
      definition = F.template_definition(cells)
      :ok = F.template!(ctx.scope, "order-shipped", "login", definition: definition)

      opts = [category: "login", message_class: "security", channels: ["sms"]]
      F.workflow!(ctx.scope, ctx.token, "login-code", opts)

      expires = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 600))
      phone = %{"phone" => "+905551112233"}

      extra = %{
        "workflow" => "login-code",
        "security_subtype" => "otp_oob",
        "expires_at" => expires
      }

      otp = send!(ctx.token, subscriber!(ctx.token, phone), extra)

      delivery = deliveries(ctx.token, otp)["sms"]
      assert run!(ctx.scope, delivery) == {:snooze, 300}

      assert [[digest, nil, nil, "security_subtype", _version, _class]] =
               snapshots(ctx.scope, delivery)

      assert digest == plan(ctx.scope, delivery).digest

      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["sms"])
      plain = send!(ctx.token, subscriber!(ctx.token, phone), %{"retention" => "none"})
      quiet = deliveries(ctx.token, plain)["sms"]

      assert run!(ctx.scope, quiet) == {:snooze, 300}
      assert [[_digest, nil, nil, "retention_none", _, _]] = snapshots(ctx.scope, quiet)
    end

    test "TP-60: a rendered delivery is not rendered again; verify matches the first digest",
         ctx do
      template!(ctx, %{"sms" => %{"body" => "Kargoda {{ order }}"}})
      workflow!(ctx, ["sms"])
      delivery = delivery!(ctx.token, subscriber!(ctx.token, %{"phone" => "+905551112233"}))

      assert run!(ctx.scope, delivery) == {:snooze, 300}
      first = plan(ctx.scope, delivery).digest
      assert run!(ctx.scope, delivery) == {:snooze, 300}
      assert %{digest: ^first, count: 1} = plan(ctx.scope, delivery)

      assert Live.verify(ctx.scope, internal(delivery)) == :rendered
      assert %{digest: ^first, count: 2} = plan(ctx.scope, delivery)
      assert length(snapshots(ctx.scope, delivery)) == 1
      assert sql!(ctx.scope, @failure, [internal(delivery)]) == [[nil, nil, nil]]
    end

    test "TP-60, TP-41: a verified digest that differs fails with schema_violation", ctx do
      template!(ctx, %{"sms" => %{"body" => "{{ brand.sender_name }}: {{ order }}"}})
      workflow!(ctx, ["sms"])
      setting!(ctx.scope, nil, "brand.sender_name", "Acme")
      delivery = delivery!(ctx.token, subscriber!(ctx.token, %{"phone" => "+905551112233"}))

      assert run!(ctx.scope, delivery) == {:snooze, 300}
      setting!(ctx.scope, nil, "brand.sender_name", "Other")
      assert run!(ctx.scope, delivery) == {:snooze, 300}
      assert Live.verify(ctx.scope, internal(delivery)) == :failed
      assert run!(ctx.scope, delivery) == :ok

      failure = sql!(ctx.scope, @failure, [internal(delivery)])
      assert failure == [["failed", "permanent_content", "schema_violation"]]

      assert [[%{"cause" => "digest_mismatch"}]] =
               sql!(ctx.scope, @render_failed, [internal(delivery)])
    end

    test "TP-41, INV-46: each render failure fails once with one ledger and one outbox event",
         ctx do
      cells = %{
        "sms" => %{"body" => "Kargo {{ carrier }}"},
        "push" => %{"title" => "Sipariş", "body" => "{{ order }}"},
        "webhook" => %{"body" => "{{ order }}"},
        "email" => email_cell("{{ order }}")
      }

      template!(ctx, cells)

      schema = %{
        "type" => "object",
        "properties" => %{
          "order" => %{"type" => "string"},
          "items" => %{"type" => "array", "items" => %{"type" => "integer"}}
        },
        "required" => ["order"]
      }

      workflow!(ctx, ["sms", "push", "webhook", "email"], event_schema: schema)
      data = %{"order" => String.duplicate("x", 5_000), "items" => [1, 2]}
      external_id = subscriber!(ctx.token, %{"phone" => "+905551112233"})
      accepted = send!(ctx.token, external_id, %{"data" => data})
      by_channel = deliveries(ctx.token, accepted)
      ref = attach([:relay, :render, :stop])

      cases = [
        {"sms", "missing_variable"},
        {"push", "output_too_large"},
        {"webhook", "schema_violation"},
        {"email", "render_timeout"}
      ]

      for {channel, reason} <- cases do
        delivery = by_channel[channel]

        limits = if channel == "email", do: [timeout_ms: 1_000, email_timeout_ms: 0]
        assert with_sandbox(limits, fn -> run!(ctx.scope, delivery) end) == :ok, channel
        expected = String.to_existing_atom(reason)
        assert_receive {^ref, _, %{result: ^expected}}
        assert run!(ctx.scope, delivery) == :ok

        failure = sql!(ctx.scope, @failure, [internal(delivery)])
        assert failure == [["failed", "permanent_content", reason]]

        assert [[detail]] = sql!(ctx.scope, @render_failed, [internal(delivery)])
        assert detail["failure_reason"] == reason
        assert detail["template"] == %{"key" => "order-shipped", "version" => 1}

        assert [payload] = outbox(ctx.scope, delivery, "notification.render_failed")

        assert payload["failure_reason"] == reason
        assert payload["channel"] == channel
      end

      assert [[%{"variable" => "carrier"}]] =
               sql!(ctx.scope, @render_failed, [internal(by_channel["sms"])])
    end

    test "TP-61: a pinned partial renders first and is inserted unescaped as partial.<key>",
         ctx do
      :ok = F.category!(ctx.token, "orders")
      {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
      content = %{"default_locale" => "tr", "bodies" => %{"tr" => "<b>{{ order }}</b>"}}

      attrs = %{
        id: Relay.Id.generate(),
        version_id: Relay.Id.generate(),
        key: "footer",
        name: "Footer",
        content: content
      }

      gate = %{findings: [], accept_warnings: false}
      at = %{key: "footer", subtenant_id: nil}

      {:ok, {:published, _, 1, _}} =
        Repo.in_scope(ctx.scope, fn _status ->
          {:created, _, _, 1} = TemplateStore.asset_create(:partial, attrs, digest(), actor)
          TemplateStore.asset_publish(:partial, at, gate, 1, digest(), actor)
        end)

      cell = email_cell("Kargo {{ order }}")
      cell = %{cell | "html" => cell["html"] <> "{{ partial.footer }}"}
      definition = F.template_definition(%{"email" => cell}, extra: [{"partials", ["footer"]}])
      :ok = F.template!(ctx.scope, "order-shipped", "orders", definition: definition)
      workflow!(ctx, ["email"])

      accepted = send!(ctx.token, subscriber!(ctx.token), %{"data" => %{"order" => "<A-1>"}})
      delivery = deliveries(ctx.token, accepted)["email"]
      assert [_partial] = plan(ctx.scope, delivery).partials
      assert run!(ctx.scope, delivery) == {:snooze, 300}

      [row] = snapshots(ctx.scope, delivery)
      {_plain, snapshot} = content(ctx.scope, recipient(accepted), row)
      assert snapshot["output"]["html"] =~ "Kargo &lt;A-1&gt;<b>&lt;A-1&gt;</b>"
    end

    test "TP-61, TP-55: a marketing legal footer carries the commercial message mark", ctx do
      :ok = F.category!(ctx.token, "news", "marketing")
      setting!(ctx.scope, nil, "brand.legal_name", "Acme Ltd")
      cells = %{"in_app" => %{"title" => "Kampanya", "body" => "Yeni {{ legal_footer }}"}}
      definition = F.template_definition(cells)
      :ok = F.template!(ctx.scope, "order-shipped", "news", definition: definition)
      opts = [category: "news", message_class: "marketing", channels: ["in_app"]]
      F.workflow!(ctx.scope, ctx.token, "newsletter", opts)

      accepted = send!(ctx.token, subscriber!(ctx.token), %{"workflow" => "newsletter"})
      delivery = deliveries(ctx.token, accepted)["in_app"]
      assert Live.verify(ctx.scope, internal(delivery)) == :rendered

      [row] = snapshots(ctx.scope, delivery)
      {_plain, snapshot} = content(ctx.scope, recipient(accepted), row)
      assert snapshot["output"]["body"] == "Yeni Acme Ltd | Ticari elektronik iletidir."
    end

    test "INV-48: the pinned version renders after a newer version is published", ctx do
      template!(ctx, %{"sms" => %{"body" => "Eski {{ order }}"}})
      workflow!(ctx, ["sms"])
      accepted = send!(ctx.token, subscriber!(ctx.token, %{"phone" => "+905551112233"}))
      delivery = deliveries(ctx.token, accepted)["sms"]
      pinned = plan(ctx.scope, delivery).version

      newer = F.template_definition(%{"sms" => %{"body" => "Yeni {{ order }}"}})
      :ok = F.publish_template!(ctx.scope, "order-shipped", newer)
      refute live_version(ctx.scope) == pinned

      assert run!(ctx.scope, delivery) == {:snooze, 300}
      [row] = snapshots(ctx.scope, delivery)
      assert Enum.at(row, 4) == pinned

      {_plain, snapshot} = content(ctx.scope, recipient(accepted), row)
      assert snapshot["output"]["text"] == "Eski A-1"
    end
  end

  defp digest, do: TenantFixture.digest()

  defp email_cell(body) do
    %{
      "subject" => body,
      "html_kind" => "raw_html",
      "html" => ~s(<html><head><meta name="color-scheme" content="light"></head><body>) <> body,
      "text" => body
    }
  end
end
