defmodule RelayTest.Isolation do
  @moduledoc """
  The negative isolation test generator (TN-16 (1), API-76, TN-15): every server API operation a router mounts that names a resource in its path is called with one credential against a resource of another scope, and must answer 404 without revealing that the resource exists. The cases come from the router and the contract, so an operation a later change mounts is covered without a new test. A path parameter needs a fixture that creates its resource in a given scope (`fixtures/0`); a mounted operation with a parameter that has none fails the generator, and so does an operation whose body has no entry in `bodies/0`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Api,
      Relay.Channels,
      Relay.Secrets,
      Relay.Workflow,
      RelayTest.Api,
      RelayTest.IngestFixture
    ],
    exports: []

  alias Relay.Api.Contract
  alias RelayTest.IngestFixture, as: F

  @parameter ~r/\{([a-z_]+)\}/
  @bodies [
    {"cancelEvent", %{}},
    {"cancelNotification", %{}},
    {"replaceSubscriber", %{"locale" => "tr-TR"}},
    {"updateSubscriber", %{"locale" => "tr-TR"}},
    {"publishWorkflow", %{}},
    {"replaceKillSwitch", %{"state" => "off", "reason" => "isolation", "ttl" => "PT1H"}},
    {"releaseKillSwitch", %{"reason" => "isolation"}},
    {"resumeKillSwitchDeliveries", %{"reason" => "isolation"}},
    {"cancelKillSwitchPausedDeliveries", %{"reason" => "isolation"}},
    {"replaceEventTypeMapping",
     %{
       "type" => "com.example.isolation",
       "workflow" => "isolation",
       "to_pointer" => "/to",
       "data_fields" => [""]
     }},
    {"updateSubscriberPreferences",
     %{"preferences" => [%{"level" => "channel", "channel" => "sms", "value" => "opt_out"}]}},
    {"updateCategory", %{"name" => "Isolation"}},
    {"replaceCategorySubtenantSetting", %{"enabled" => false}},
    {"replaceCategoryEmailTracking", %{"open_pixel" => false, "wrap_links" => false}},
    {"replaceTemplateEmailTracking", %{"open_pixel" => false, "wrap_links" => false}},
    {"liftSuppression", %{"reason" => "isolation"}},
    {"registerSubscriberDevice",
     %{
       "platform" => "fcm",
       "token" => "fcm:isolation-device",
       "app" => "com.example.isolation",
       "permission" => "granted"
     }},
    {"publishTemplate", %{}},
    {"previewTemplate", %{"workflow" => "iso-preview"}},
    {"publishLayout", %{}},
    {"replaceLayoutDraft", %{"definition" => %{"mjml" => "<mjml><mj-body></mj-body></mjml>"}}},
    {"publishPartial", %{}},
    {"replacePartialDraft",
     %{"definition" => %{"default_locale" => "tr", "bodies" => %{"tr" => "Merhaba"}}}},
    {"previewWorkflow", %{}},
    {"sendWorkflowTest", %{"to" => ["trc_01j9zq3k4m5n6p7q8r9s0t1v2w"]}},
    {"replaceSubscriberMessagingTarget",
     %{"provider_account_id" => "pva_01j9zq3k4m5n6p7q8r9s0t1v2w", "conversation" => "U1"}},
    {"updateProviderAccount", %{"priority" => 5}},
    {"updateSenderIdentity", %{"country" => "TR"}},
    {"updateChannelIdentity", %{"app_ref" => "com.example.isolation"}},
    {"addTopicSubscriptions", %{"subscribers" => ["isolation-subscriber"]}},
    {"removeTopicSubscriptions", %{"subscribers" => ["isolation-subscriber"]}},
    {"replaceRoute", %{"name" => "Isolation", "tree" => "email"}}
  ]
  @upserts %{"replaceSubscriber" => 201, "publishProducerTemplate" => 200}
  @sms %{
    "default_locale" => "tr",
    "sensitivity" => "public",
    "cells" => %{"sms" => %{"tr" => %{"body" => "Kodunuz hazır"}}}
  }

  @doc "The server operations with path parameters that `router` mounts, authenticated with an Access token."
  @spec operations(module()) :: [Contract.operation()]
  def operations(router) do
    mounted = MapSet.new(RelayTest.Api.routes(router))

    for operation <- Contract.operations(),
        operation.family == :server and operation.security == :bearer,
        MapSet.member?(mounted, {operation.method, operation.path}),
        parameters(operation) != [],
        do: operation
  end

  @doc "The path parameters of an operation."
  @spec parameters(Contract.operation()) :: [String.t()]
  def parameters(operation),
    do: Enum.map(Regex.scan(@parameter, operation.path), fn [_, name] -> name end)

  @doc "The fixtures by path parameter: each creates its resource in a scope and returns its external identifier."
  @spec fixtures() :: %{String.t() => (Relay.Scope.t() -> String.t())}
  def fixtures do
    %{
      "kill_switch_id" => &kill_switch!/1,
      "event_id" => &event!(&1, :event),
      "notification_id" => &event!(&1, :notification),
      "delivery_id" => &event!(&1, :delivery),
      "subscriber_id" => &subscriber!/1,
      "workflow_key" => &workflow!/1,
      "version" => fn _scope -> "1" end,
      "mapping_id" => &mapping!/1,
      "category_key" => &category!/1,
      "route_key" => &route!/1,
      "subtenant_id" => &subtenant!/1,
      "suppression_id" => &suppression!/1,
      "device_id" => &device!/1,
      "whatsapp_template_id" => &whatsapp_template!/1,
      "template_key" => &template!/1,
      "layout_key" => &asset!(&1, "layouts"),
      "partial_key" => &asset!(&1, "partials"),
      "channel" => &messaging_target!/1,
      "provider_account_id" => &provider_account!/1,
      "sender_identity_id" => &sender_identity!/1,
      "channel_identity_id" => &channel_identity!/1,
      "test_recipient_id" => &test_recipient!/1,
      "provider_invoice_id" => &provider_invoice!/1,
      "export_id" => &export!/1,
      "topic_key" => &topic!/1,
      "recurrence_id" => &recurrence!/1,
      "throttle_key" => &throttle!/1
    }
  end

  @doc "The operations whose path names a resource they create when it is missing, with the status of a creation: the caller's own scope gets a new one and the other scope's resource is never found."
  @spec upserts() :: %{String.t() => pos_integer()}
  def upserts, do: @upserts

  @doc "Request bodies by operation for operations that take one."
  @spec bodies() :: %{String.t() => map()}
  def bodies do
    @bodies
    |> Map.new()
    |> Map.put("replaceWorkflowDraft", %{"definition" => F.definition()})
    |> Map.put("replaceTemplateDraft", %{"definition" => @sms})
    |> Map.put("publishProducerTemplate", %{
      "name" => "Isolation",
      "category" => "security",
      "definition" => @sms,
      "accept_warnings" => true
    })
  end

  @doc "The path parameters of an operation without a fixture, and whether its body is missing."
  @spec gaps(Contract.operation()) :: [String.t()]
  def gaps(operation) do
    missing = Enum.reject(parameters(operation), &Map.has_key?(fixtures(), &1))
    body? = operation.request != %{} and not Map.has_key?(bodies(), operation.id)
    if body?, do: ["body" | missing], else: missing
  end

  @doc "Creates the resources an operation's path names in `scope` and returns the request path."
  @spec path(Contract.operation(), Relay.Scope.t()) :: String.t()
  def path(operation, scope) do
    ids = Map.new(parameters(operation), &{&1, Map.fetch!(fixtures(), &1).(scope)})
    Regex.replace(@parameter, operation.path, fn _match, name -> Map.fetch!(ids, name) end)
  end

  @doc "Calls an operation at `path` with `token` through `router`."
  @spec call(module(), Contract.operation(), String.t(), String.t()) :: Plug.Conn.t()
  def call(router, operation, path, token) do
    method = operation.method |> String.downcase() |> String.to_existing_atom()
    body = Map.get(bodies(), operation.id)
    key = {"idempotency-key", "isolation-" <> Base.encode16(:crypto.strong_rand_bytes(6))}

    headers = RelayTest.Api.auth(token, method, path) ++ [key, {"if-match", ~s("999")}]

    conn =
      if body,
        do: body_request(operation, method, path, body, headers),
        else: RelayTest.Api.conn(method, path, nil, headers)

    RelayTest.Api.call(conn, router)
  end

  defp body_request(operation, method, path, body, headers) do
    [media | _] = Map.keys(operation.request)
    RelayTest.Api.conn(method, path, Jason.encode!(body), [{"content-type", media} | headers])
  end

  defp owner(scope), do: F.token(scope)

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  @doc "Publishes a workflow in `scope` once per test process and returns its key; the other scope's calls never change it."
  @spec workflow!(Relay.Scope.t()) :: String.t()
  def workflow!(scope) do
    cache = {__MODULE__, :workflow, scope.tenant_id, scope.environment}

    case Process.get(cache) do
      nil ->
        key = "iso-" <> random()
        F.workflow!(scope, owner(scope), key)
        Process.put(cache, key)
        key

      key ->
        key
    end
  end

  @doc "Publishes an SMS template in `scope`, with the `iso-preview` workflow its preview names, and returns its key."
  @spec template!(Relay.Scope.t()) :: String.t()
  def template!(scope) do
    token = owner(scope)
    cache = {__MODULE__, :preview_workflow, scope.tenant_id, scope.environment}

    if Process.get(cache) == nil do
      F.workflow!(scope, token, "iso-preview")
      Process.put(cache, true)
    end

    key = "iso-" <> random()
    body = %{"key" => key, "name" => "Isolation", "category" => "orders", "definition" => @sms}
    created = F.request(:post, "/v1/templates", token, body)
    F.body(created, 201)
    [etag] = Plug.Conn.get_resp_header(created, "etag")
    path = "/v1/templates/#{key}/publish"
    F.body(F.request(:post, path, token, %{}, [{"if-match", etag}]), 200)
    key
  end

  @doc "Creates and publishes a layout or partial in `scope` and returns its key."
  @spec asset!(Relay.Scope.t(), String.t()) :: String.t()
  def asset!(scope, collection) do
    token = owner(scope)
    key = "iso-" <> random()

    definition =
      if collection == "layouts",
        do: %{"mjml" => "<mjml><mj-body></mj-body></mjml>"},
        else: %{"default_locale" => "tr", "bodies" => %{"tr" => "Merhaba"}}

    body = %{"key" => key, "name" => "Isolation", "definition" => definition}
    created = F.request(:post, "/v1/#{collection}", token, body)
    F.body(created, 201)
    [etag] = Plug.Conn.get_resp_header(created, "etag")
    path = "/v1/#{collection}/#{key}/publish"
    published = F.request(:post, path, token, %{"accept_warnings" => true}, [{"if-match", etag}])
    F.body(published, 200)
    key
  end

  @doc "Accepts an event in `scope` and returns the identifier of the event, its notification or its delivery."
  @spec event!(Relay.Scope.t(), :event | :notification | :delivery) :: String.t()
  def event!(scope, which) do
    token = owner(scope)
    to = [%{"id" => "iso-" <> random(), "email" => "i@example.com"}]
    body = %{"workflow" => workflow!(scope), "to" => to, "data" => %{"order" => "I-1"}}
    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]

    case which do
      :event ->
        accepted["id"]

      :notification ->
        notification

      :delivery ->
        path = "/v1/notifications/#{notification}/deliveries"
        [%{"id" => delivery}] = F.body(F.request(:get, path, token), 200)["data"]
        delivery
    end
  end

  @doc "Creates a subscriber in `scope` and returns its external identifier; it is also the owner of the next `device!/1` of the scope."
  @spec subscriber!(Relay.Scope.t()) :: String.t()
  def subscriber!(scope) do
    id = "iso-" <> random()
    body = %{"external_id" => id, "email" => "s@example.com"}
    F.body(F.request(:post, "/v1/subscribers", owner(scope), body), 201)
    Process.put({__MODULE__, :subscriber, scope.tenant_id, scope.environment}, id)
    id
  end

  @doc "Registers a device in `scope` for the subscriber `subscriber!/1` created last in the scope (a new one when there is none) and returns the device's identifier."
  @spec device!(Relay.Scope.t()) :: String.t()
  def device!(scope) do
    key = {__MODULE__, :subscriber, scope.tenant_id, scope.environment}
    subscriber = Process.get(key) || subscriber!(scope)

    body = %{
      "platform" => "fcm",
      "token" => "fcm:iso-" <> random(),
      "app" => "com.example.isolation",
      "permission" => "granted"
    }

    path = "/v1/subscribers/#{subscriber}/devices"
    F.body(F.request(:post, path, owner(scope), body), 201)["id"]
  end

  @doc "Puts a Slack conversation in `scope` for the subscriber `subscriber!/1` created last in the scope (a new one when there is none), on a new Slack provider account, and returns the channel."
  @spec messaging_target!(Relay.Scope.t()) :: String.t()
  def messaging_target!(scope) do
    key = {__MODULE__, :subscriber, scope.tenant_id, scope.environment}
    subscriber = Process.get(key) || subscriber!(scope)
    id = Relay.Id.generate()

    account = %{
      id: id,
      channel: "slack",
      provider: "slack",
      ownership: "shared",
      role: "primary",
      priority: 0,
      processing_countries: ["US"],
      transfer_basis: "adequacy"
    }

    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    digest = :crypto.strong_rand_bytes(32)
    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, account, digest, actor)

    body = %{"provider_account_id" => Relay.ExternalId.encode("pva", id), "conversation" => "U1"}
    path = "/v1/subscribers/#{subscriber}/messaging_targets/slack"
    F.body(F.request(:put, path, owner(scope), body), 201)
    "slack"
  end

  @doc "Creates a provider account in `scope` and returns its identifier."
  @spec provider_account!(Relay.Scope.t()) :: String.t()
  def provider_account!(scope), do: Relay.ExternalId.encode("pva", account!(scope))

  @doc "Creates a sender identity in `scope` and returns its identifier."
  @spec sender_identity!(Relay.Scope.t()) :: String.t()
  def sender_identity!(scope) do
    id = Relay.Id.generate()

    sender = %{
      id: id,
      provider_account_id: account!(scope),
      channel: "email",
      kind: "email_domain",
      value: "iso-" <> random() <> ".example.com",
      approval_state: "pending"
    }

    {:ok, {:created, 1}} = Relay.Channels.put_sender_identity(scope, sender, digest(), system())
    Relay.ExternalId.encode("snd", id)
  end

  @doc "Creates a channel identity with a registered secret in `scope` and returns its identifier."
  @spec channel_identity!(Relay.Scope.t()) :: String.t()
  def channel_identity!(scope) do
    var = "RELAY_TEST_ISOLATION_" <> String.upcase(random())
    System.put_env(var, "isolation-secret-" <> random())
    secret_id = Relay.Id.generate()

    secret = %{
      id: secret_id,
      kind: :channel_identity,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, secret, system())
    id = Relay.Id.generate()

    identity = %{
      id: id,
      channel: "slack",
      kind: "slack_app",
      app_ref: "A" <> random(),
      secret_ref_id: secret_id
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_channel_identity(scope, identity, digest(), system())

    Relay.ExternalId.encode("chi", id)
  end

  defp account!(scope) do
    id = Relay.Id.generate()

    account = %{
      id: id,
      channel: "email",
      provider: "fake",
      ownership: "shared",
      role: "primary",
      priority: 0,
      in_installation: true,
      transfer_basis: "none"
    }

    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, account, digest(), system())
    id
  end

  defp system do
    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    actor
  end

  defp digest, do: :crypto.strong_rand_bytes(32)

  @doc "Creates a CloudEvents type mapping in `scope` and returns its identifier."
  @spec mapping!(Relay.Scope.t()) :: String.t()
  def mapping!(scope) do
    body = %{
      "type" => "com.example.iso." <> random(),
      "workflow" => workflow!(scope),
      "to_pointer" => "/to",
      "data_fields" => [""]
    }

    created = F.request(:post, "/v1/event_type_mappings", owner(scope), body)
    F.body(created, 201)["id"]
  end

  @doc "Creates a category in `scope` and returns its key."
  @spec category!(Relay.Scope.t()) :: String.t()
  def category!(scope) do
    key = "iso_" <> random()
    :ok = F.category!(owner(scope), key)
    key
  end

  @doc "Creates a named route in `scope` and returns its key."
  @spec route!(Relay.Scope.t()) :: String.t()
  def route!(scope) do
    key = "iso_" <> random()
    body = %{"key" => key, "name" => "Isolation", "tree" => %{"single" => ["push", "email"]}}
    F.body(F.request(:post, "/v1/routes", owner(scope), body), 201)
    key
  end

  @doc "Creates a sub-tenant in `scope` and returns its identifier."
  @spec subtenant!(Relay.Scope.t()) :: String.t()
  def subtenant!(scope) do
    id = Relay.Id.generate()
    actor = ["system", "relay-test", "relay-test", nil]
    params = [id, "org_iso_" <> random(), "Isolation", :crypto.strong_rand_bytes(32)] ++ actor

    {:ok, [%{"result" => "created"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.subtenant_upsert", params)
      end)

    Relay.ExternalId.encode("stn", id)
  end

  @doc "Suppresses an address in `scope` by hand and returns the suppression's identifier."
  @spec suppression!(Relay.Scope.t()) :: String.t()
  def suppression!(scope) do
    body = %{"channel" => "email", "address" => "iso-" <> random() <> "@example.com"}
    F.body(F.request(:post, "/v1/suppressions", owner(scope), body), 201)["id"]
  end

  @doc "Adds the subscriber `subscriber!/1` creates to the test recipient list of `scope` and returns the entry's identifier."
  @spec test_recipient!(Relay.Scope.t()) :: String.t()
  def test_recipient!(scope) do
    body = %{"subscriber_id" => subscriber!(scope)}
    F.body(F.request(:post, "/v1/test_recipients", owner(scope), body), 201)["id"]
  end

  @doc "Counts an event on a fresh throttle key in `scope`, so the key has an active window, and returns the key."
  @spec throttle!(Relay.Scope.t()) :: String.t()
  def throttle!(scope) do
    key = "iso-" <> random()
    step = %{"key" => key, "limit" => 5, "window" => "PT1H"}
    {:ok, %{outcome: :allowed}} = Relay.Workflow.throttle_now(scope, step, %{key: key, ref: key})
    key
  end

  @doc "Requests a raw data export in `scope` and returns its identifier."
  @spec export!(Relay.Scope.t()) :: String.t()
  def export!(scope) do
    body = %{"kind" => "usage_records", "from" => "2026-10-01", "to" => "2026-11-01"}
    F.body(F.request(:post, "/v1/exports", owner(scope), body), 202)["id"]
  end

  @doc "Creates a topic in `scope` and returns its key."
  @spec topic!(Relay.Scope.t()) :: String.t()
  def topic!(scope) do
    key = "iso:" <> random()
    F.body(F.request(:post, "/v1/topics", owner(scope), %{"key" => key}), 201)["key"]
  end

  @doc "Defines a daily recurrence rule in `scope` for a new subscriber and returns its identifier."
  @spec recurrence!(Relay.Scope.t()) :: String.t()
  def recurrence!(scope) do
    body = %{
      "workflow" => workflow!(scope),
      "subscriber_id" => subscriber!(scope),
      "rrule" => "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      "dtstart" => "2026-11-01T09:00:00",
      "data" => %{"order" => "A-1"}
    }

    F.body(F.request(:post, "/v1/recurrences", owner(scope), body), 201)["id"]
  end

  @doc "Records a provider invoice in `scope` and returns its identifier."
  @spec provider_invoice!(Relay.Scope.t()) :: String.t()
  def provider_invoice!(scope) do
    body = %{
      "provider" => "netgsm",
      "invoice_ref" => "iso-" <> random(),
      "period_start" => "2026-10-01",
      "period_end" => "2026-11-01",
      "currency" => "TRY",
      "amount_micros" => "0"
    }

    F.body(F.request(:post, "/v1/provider_invoices", owner(scope), body), 201)["id"]
  end

  @doc "Registers a WhatsApp template on a new WhatsApp provider account in `scope` and returns the template's identifier."
  @spec whatsapp_template!(Relay.Scope.t()) :: String.t()
  def whatsapp_template!(scope) do
    account_id = Relay.Id.generate()
    template_id = Relay.Id.generate()
    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    digest = :crypto.strong_rand_bytes(32)

    account =
      [account_id, "whatsapp", "whatsapp_cloud", "shared", nil, "primary", 0, 0, false, ["US"]] ++
        ["explicit_consent", nil, %{"phone_number_id" => "1"}, nil, digest] ++
        Relay.Actor.params(actor)

    template =
      [template_id, account_id, "1", "iso_" <> random(), "en_US", "transactional", "utility"] ++
        [[%{"type" => "BODY", "text" => "Hello {{1}}"}], digest]

    {:ok, [%{"result" => "created"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        [%{"result" => "created"}] = Relay.Repo.call!("relay_fn.provider_account_put", account)
        Relay.Repo.call!("relay_fn.whatsapp_template_register", template)
      end)

    Relay.ExternalId.encode("wtp", template_id)
  end

  @doc "Engages a tenant-scope kill switch in `scope` and returns its identifier."
  @spec kill_switch!(Relay.Scope.t()) :: String.t()
  def kill_switch!(scope) do
    id = Relay.Id.generate()
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    params = [
      id,
      "tenant",
      nil,
      nil,
      "all",
      nil,
      nil,
      nil,
      "off",
      nil,
      nil,
      "isolation",
      "INC-1",
      expires_at,
      nil,
      "operator",
      :crypto.strong_rand_bytes(32),
      "operator",
      "acc_op_1",
      "acc_op_1",
      nil
    ]

    {:ok, [%{"result" => "engaged"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.kill_switch_engage", params)
      end)

    Relay.ExternalId.encode("ksw", id)
  end
end
