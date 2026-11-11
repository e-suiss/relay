defmodule RelayWeb.Router do
  use RelayWeb, :router

  import Oban.Web.Router

  @panel_session RelayWeb.Operator.Panel.session_options()

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :v1 do
    plug RelayWeb.Api.Pipeline
  end

  pipeline :operator do
    plug RelayWeb.Operator.Pipeline
  end

  pipeline :panel do
    plug :accepts, ["html"]
    plug Plug.Session, @panel_session
    plug :fetch_session
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    }

    plug RelayWeb.Operator.Panel
  end

  pipeline :links do
    plug Plug.Parsers, parsers: [:urlencoded, :multipart], length: 8_192

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      "cache-control" => "no-store",
      "referrer-policy" => "no-referrer",
      "x-robots-tag" => "noindex"
    }
  end

  pipeline :downloads do
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
      "cache-control" => "no-store",
      "referrer-policy" => "no-referrer",
      "x-robots-tag" => "noindex"
    }
  end

  pipeline :tracking do
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
      "cache-control" => "no-store",
      "referrer-policy" => "no-referrer",
      "x-robots-tag" => "noindex"
    }
  end

  scope "/", RelayWeb do
    pipe_through :api

    get "/livez", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  # CH-76
  # CH-44
  # PC-35
  scope "/links", RelayWeb do
    pipe_through :links

    get "/:token", LinkController, :show
    post "/:token", LinkController, :create
  end

  # DS-37
  scope "/exports", RelayWeb do
    pipe_through :downloads

    get "/:token", ExportDownloadController, :show
  end

  # CH-43
  # CH-44
  # DS-30
  # DS-32
  scope "/e", RelayWeb do
    pipe_through :tracking

    get "/c/:token", TrackingController, :click
    get "/o/:token", TrackingController, :open
  end

  # CH-62
  # WH-49
  scope "/inbound/v1", RelayWeb do
    post "/providers/:provider_account_id", ProviderWebhookController, :create,
      private: %{relay_operation: "receiveProviderWebhook"}

    post "/:channel/:tenant/:environment/:identity", InboundController, :create,
      private: %{relay_operation: "receiveMessagingInbound"}
  end

  # E-94
  scope "/v1/access", RelayWeb do
    post "/events", AccessEventController, :create,
      private: %{relay_operation: "receiveAccessEvent"}
  end

  # E-81
  # E-89
  scope "/.well-known", RelayWeb.Api do
    pipe_through :v1

    get "/relay-configuration", DiscoveryController, :configuration,
      private: %{relay_operation: "getRelayConfiguration"}

    get "/relay-jwks.json", DiscoveryController, :jwks,
      private: %{relay_operation: "getRelayJwks"}
  end

  # API-6
  scope "/v1", RelayWeb.Api do
    pipe_through :v1

    get "/errors/:code", ErrorCodeController, :show, private: %{relay_operation: "getErrorCode"}

    post "/events", EventController, :create, private: %{relay_operation: "createEvent"}

    post "/events/batch", EventController, :batch, private: %{relay_operation: "createEventBatch"}

    post "/events/cancel_by_key", EventController, :cancel_by_key,
      private: %{relay_operation: "cancelEventsByKey"}

    get "/events/:event_id", EventController, :show, private: %{relay_operation: "getEvent"}

    post "/events/:event_id/cancel", EventController, :cancel,
      private: %{relay_operation: "cancelEvent"}

    get "/notifications", NotificationController, :index,
      private: %{relay_operation: "listNotifications"}

    get "/notifications/:notification_id", NotificationController, :show,
      private: %{relay_operation: "getNotification"}

    post "/notifications/:notification_id/cancel", NotificationController, :cancel,
      private: %{relay_operation: "cancelNotification"}

    get "/notifications/:notification_id/deliveries", NotificationController, :deliveries,
      private: %{relay_operation: "listNotificationDeliveries"}

    get "/deliveries/:delivery_id/history", DeliveryController, :history,
      private: %{relay_operation: "getDeliveryHistory"}

    get "/subscribers/:subscriber_id/decisions", NotificationController, :decisions,
      private: %{relay_operation: "listSubscriberDecisions"}

    post "/subscribers/bulk", SubscriberController, :bulk,
      private: %{relay_operation: "bulkUpsertSubscribers"}

    post "/subscribers", SubscriberController, :create,
      private: %{relay_operation: "createSubscriber"}

    get "/subscribers", SubscriberController, :index,
      private: %{relay_operation: "listSubscribers"}

    get "/subscribers/:subscriber_id", SubscriberController, :show,
      private: %{relay_operation: "getSubscriber"}

    put "/subscribers/:subscriber_id", SubscriberController, :replace,
      private: %{relay_operation: "replaceSubscriber"}

    patch "/subscribers/:subscriber_id", SubscriberController, :update,
      private: %{relay_operation: "updateSubscriber"}

    delete "/subscribers/:subscriber_id", SubscriberController, :delete,
      private: %{relay_operation: "deleteSubscriber"}

    get "/subscribers/:subscriber_id/preferences", PreferenceController, :show,
      private: %{relay_operation: "getSubscriberPreferences"}

    patch "/subscribers/:subscriber_id/preferences", PreferenceController, :update,
      private: %{relay_operation: "updateSubscriberPreferences"}

    get "/subscribers/:subscriber_id/consents", PreferenceController, :consents,
      private: %{relay_operation: "listSubscriberConsents"}

    get "/subscribers/:subscriber_id/devices", DeviceController, :index,
      private: %{relay_operation: "listSubscriberDevices"}

    post "/subscribers/:subscriber_id/devices", DeviceController, :create,
      private: %{relay_operation: "registerSubscriberDevice"}

    delete "/subscribers/:subscriber_id/devices/:device_id", DeviceController, :delete,
      private: %{relay_operation: "deleteSubscriberDevice"}

    delete "/devices/by-token", DeviceController, :delete_by_token,
      private: %{relay_operation: "deleteDeviceByToken"}

    put "/subscribers/:subscriber_id/messaging_targets/:channel", MessagingController, :put,
      private: %{relay_operation: "replaceSubscriberMessagingTarget"}

    delete "/subscribers/:subscriber_id/messaging_targets/:channel", MessagingController, :delete,
      private: %{relay_operation: "deleteSubscriberMessagingTarget"}

    post "/messaging_installations", MessagingController, :install,
      private: %{relay_operation: "createMessagingInstallation"}

    get "/messaging_installations/callback", MessagingController, :callback,
      private: %{relay_operation: "completeMessagingInstallation"}

    get "/channel_adapters", MessagingController, :adapters,
      private: %{relay_operation: "listChannelAdapters"}

    get "/whatsapp/templates", WhatsappTemplateController, :index,
      private: %{relay_operation: "listWhatsappTemplates"}

    post "/whatsapp/templates", WhatsappTemplateController, :create,
      private: %{relay_operation: "registerWhatsappTemplate"}

    get "/whatsapp/templates/:whatsapp_template_id", WhatsappTemplateController, :show,
      private: %{relay_operation: "getWhatsappTemplate"}

    get "/provider_accounts", ChannelController, :accounts,
      private: %{relay_operation: "listProviderAccounts"}

    get "/provider_accounts/:provider_account_id", ChannelController, :account,
      private: %{relay_operation: "getProviderAccount"}

    patch "/provider_accounts/:provider_account_id", ChannelController, :update_account,
      private: %{relay_operation: "updateProviderAccount"}

    post "/provider_accounts/:provider_account_id/verify", ChannelController, :verify_account,
      private: %{relay_operation: "verifyProviderAccount"}

    get "/provider_invoices", ProviderInvoiceController, :index,
      private: %{relay_operation: "listProviderInvoices"}

    post "/provider_invoices", ProviderInvoiceController, :create,
      private: %{relay_operation: "createProviderInvoice"}

    get "/provider_invoices/:provider_invoice_id", ProviderInvoiceController, :show,
      private: %{relay_operation: "getProviderInvoice"}

    get "/reports/deliveries", ReportController, :deliveries,
      private: %{relay_operation: "getDeliveryReport"}

    get "/reports/skips", ReportController, :skips, private: %{relay_operation: "getSkipReport"}

    get "/reports/costs", ReportController, :costs, private: %{relay_operation: "getCostReport"}

    get "/exports", ExportController, :index, private: %{relay_operation: "listExports"}

    post "/exports", ExportController, :create, private: %{relay_operation: "createExport"}

    get "/exports/:export_id", ExportController, :show, private: %{relay_operation: "getExport"}

    get "/sender_identities", ChannelController, :senders,
      private: %{relay_operation: "listSenderIdentities"}

    post "/sender_identities", ChannelController, :create_sender,
      private: %{relay_operation: "createSenderIdentity"}

    get "/sender_identities/:sender_identity_id", ChannelController, :sender,
      private: %{relay_operation: "getSenderIdentity"}

    patch "/sender_identities/:sender_identity_id", ChannelController, :update_sender,
      private: %{relay_operation: "updateSenderIdentity"}

    post "/sender_identities/:sender_identity_id/archive", ChannelController, :archive_sender,
      private: %{relay_operation: "archiveSenderIdentity"}

    get "/channel_identities", ChannelController, :channel_identities,
      private: %{relay_operation: "listChannelIdentities"}

    get "/channel_identities/:channel_identity_id", ChannelController, :channel_identity,
      private: %{relay_operation: "getChannelIdentity"}

    patch "/channel_identities/:channel_identity_id", ChannelController, :update_channel_identity,
      private: %{relay_operation: "updateChannelIdentity"}

    post "/channel_identities/:channel_identity_id/archive",
         ChannelController,
         :archive_channel_identity,
         private: %{relay_operation: "archiveChannelIdentity"}

    get "/categories", CategoryController, :index, private: %{relay_operation: "listCategories"}

    post "/categories", CategoryController, :create, private: %{relay_operation: "createCategory"}

    get "/categories/:category_key", CategoryController, :show,
      private: %{relay_operation: "getCategory"}

    patch "/categories/:category_key", CategoryController, :update,
      private: %{relay_operation: "updateCategory"}

    post "/categories/:category_key/archive", CategoryController, :archive,
      private: %{relay_operation: "archiveCategory"}

    get "/categories/:category_key/subtenants/:subtenant_id", CategoryController, :setting,
      private: %{relay_operation: "getCategorySubtenantSetting"}

    put "/categories/:category_key/subtenants/:subtenant_id", CategoryController, :put_setting,
      private: %{relay_operation: "replaceCategorySubtenantSetting"}

    get "/categories/:category_key/email_tracking", EmailTrackingController, :show,
      private: %{relay_operation: "getCategoryEmailTracking", relay_target: "category"}

    put "/categories/:category_key/email_tracking", EmailTrackingController, :replace,
      private: %{relay_operation: "replaceCategoryEmailTracking", relay_target: "category"}

    get "/templates/:template_key/email_tracking", EmailTrackingController, :show,
      private: %{relay_operation: "getTemplateEmailTracking", relay_target: "template"}

    put "/templates/:template_key/email_tracking", EmailTrackingController, :replace,
      private: %{relay_operation: "replaceTemplateEmailTracking", relay_target: "template"}

    post "/email_reports", EmailReportController, :create,
      private: %{relay_operation: "uploadEmailReport"}

    get "/email_reports/summary", EmailReportController, :summary,
      private: %{relay_operation: "getEmailReportSummary"}

    get "/suppressions", SuppressionController, :index,
      private: %{relay_operation: "listSuppressions"}

    post "/suppressions", SuppressionController, :create,
      private: %{relay_operation: "createSuppression"}

    post "/suppressions/:suppression_id/lift", SuppressionController, :lift,
      private: %{relay_operation: "liftSuppression"}

    get "/workflows", WorkflowController, :index, private: %{relay_operation: "listWorkflows"}
    post "/workflows", WorkflowController, :create, private: %{relay_operation: "createWorkflow"}

    get "/workflows/:workflow_key", WorkflowController, :show,
      private: %{relay_operation: "getWorkflow"}

    put "/workflows/:workflow_key", WorkflowController, :replace,
      private: %{relay_operation: "replaceWorkflowDraft"}

    post "/workflows/:workflow_key/publish", WorkflowController, :publish,
      private: %{relay_operation: "publishWorkflow"}

    get "/workflows/:workflow_key/versions", WorkflowController, :versions,
      private: %{relay_operation: "listWorkflowVersions"}

    get "/workflows/:workflow_key/versions/:version", WorkflowController, :version,
      private: %{relay_operation: "getWorkflowVersion"}

    post "/workflows/:workflow_key/versions/:version/promote", WorkflowController, :promote,
      private: %{relay_operation: "promoteWorkflowVersion"}

    post "/workflows/:workflow_key/preview", WorkflowController, :preview,
      private: %{relay_operation: "previewWorkflow"}

    post "/workflows/:workflow_key/test", WorkflowController, :test_send,
      private: %{relay_operation: "sendWorkflowTest"}

    get "/test_recipients", TesterController, :index,
      private: %{relay_operation: "listTestRecipients"}

    post "/test_recipients", TesterController, :create,
      private: %{relay_operation: "createTestRecipient"}

    post "/test_recipients/:test_recipient_id/remove", TesterController, :remove,
      private: %{relay_operation: "removeTestRecipient"}

    get "/templates", TemplateController, :index, private: %{relay_operation: "listTemplates"}
    post "/templates", TemplateController, :create, private: %{relay_operation: "createTemplate"}

    get "/templates/:template_key", TemplateController, :show,
      private: %{relay_operation: "getTemplate"}

    put "/templates/:template_key", TemplateController, :replace,
      private: %{relay_operation: "replaceTemplateDraft"}

    post "/templates/:template_key/publish", TemplateController, :publish,
      private: %{relay_operation: "publishTemplate"}

    post "/templates/:template_key/archive", TemplateController, :archive,
      private: %{relay_operation: "archiveTemplate"}

    get "/templates/:template_key/versions", TemplateController, :versions,
      private: %{relay_operation: "listTemplateVersions"}

    get "/templates/:template_key/versions/:version", TemplateController, :version,
      private: %{relay_operation: "getTemplateVersion"}

    post "/templates/:template_key/versions/:version/promote", TemplateController, :promote,
      private: %{relay_operation: "promoteTemplateVersion"}

    get "/templates/:template_key/translations", TemplateController, :translations,
      private: %{relay_operation: "getTemplateTranslations"}

    post "/templates/:template_key/preview", TemplateController, :preview,
      private: %{relay_operation: "previewTemplate"}

    put "/producer_templates/:template_key", TemplateController, :producer,
      private: %{relay_operation: "publishProducerTemplate"}

    get "/layouts", TemplateAssetController, :index,
      private: %{relay_operation: "listLayouts", relay_kind: :layout}

    post "/layouts", TemplateAssetController, :create,
      private: %{relay_operation: "createLayout", relay_kind: :layout}

    get "/layouts/:layout_key", TemplateAssetController, :show,
      private: %{relay_operation: "getLayout", relay_kind: :layout}

    put "/layouts/:layout_key", TemplateAssetController, :replace,
      private: %{relay_operation: "replaceLayoutDraft", relay_kind: :layout}

    post "/layouts/:layout_key/publish", TemplateAssetController, :publish,
      private: %{relay_operation: "publishLayout", relay_kind: :layout}

    post "/layouts/:layout_key/archive", TemplateAssetController, :archive,
      private: %{relay_operation: "archiveLayout", relay_kind: :layout}

    get "/layouts/:layout_key/versions", TemplateAssetController, :versions,
      private: %{relay_operation: "listLayoutVersions", relay_kind: :layout}

    get "/layouts/:layout_key/versions/:version", TemplateAssetController, :version,
      private: %{relay_operation: "getLayoutVersion", relay_kind: :layout}

    post "/layouts/:layout_key/versions/:version/promote", TemplateAssetController, :promote,
      private: %{relay_operation: "promoteLayoutVersion", relay_kind: :layout}

    get "/partials", TemplateAssetController, :index,
      private: %{relay_operation: "listPartials", relay_kind: :partial}

    post "/partials", TemplateAssetController, :create,
      private: %{relay_operation: "createPartial", relay_kind: :partial}

    get "/partials/:partial_key", TemplateAssetController, :show,
      private: %{relay_operation: "getPartial", relay_kind: :partial}

    put "/partials/:partial_key", TemplateAssetController, :replace,
      private: %{relay_operation: "replacePartialDraft", relay_kind: :partial}

    post "/partials/:partial_key/publish", TemplateAssetController, :publish,
      private: %{relay_operation: "publishPartial", relay_kind: :partial}

    post "/partials/:partial_key/archive", TemplateAssetController, :archive,
      private: %{relay_operation: "archivePartial", relay_kind: :partial}

    get "/partials/:partial_key/versions", TemplateAssetController, :versions,
      private: %{relay_operation: "listPartialVersions", relay_kind: :partial}

    get "/partials/:partial_key/versions/:version", TemplateAssetController, :version,
      private: %{relay_operation: "getPartialVersion", relay_kind: :partial}

    post "/partials/:partial_key/versions/:version/promote", TemplateAssetController, :promote,
      private: %{relay_operation: "promotePartialVersion", relay_kind: :partial}

    get "/brand", BrandController, :show, private: %{relay_operation: "getBrand"}
    patch "/brand", BrandController, :update, private: %{relay_operation: "updateBrand"}

    get "/event_type_mappings", MappingController, :index,
      private: %{relay_operation: "listEventTypeMappings"}

    post "/event_type_mappings", MappingController, :create,
      private: %{relay_operation: "createEventTypeMapping"}

    get "/event_type_mappings/:mapping_id", MappingController, :show,
      private: %{relay_operation: "getEventTypeMapping"}

    put "/event_type_mappings/:mapping_id", MappingController, :replace,
      private: %{relay_operation: "replaceEventTypeMapping"}

    post "/event_type_mappings/:mapping_id/archive", MappingController, :archive,
      private: %{relay_operation: "archiveEventTypeMapping"}

    get "/kill_switches", KillSwitchController, :index,
      private: %{relay_operation: "listKillSwitches"}

    post "/kill_switches", KillSwitchController, :create,
      private: %{relay_operation: "engageKillSwitch"}

    get "/kill_switches/:kill_switch_id", KillSwitchController, :show,
      private: %{relay_operation: "getKillSwitch"}

    post "/kill_switches/:kill_switch_id/replace", KillSwitchController, :replace,
      private: %{relay_operation: "replaceKillSwitch"}

    post "/kill_switches/:kill_switch_id/release", KillSwitchController, :release,
      private: %{relay_operation: "releaseKillSwitch"}

    post "/kill_switches/:kill_switch_id/resume", KillSwitchController, :resume,
      private: %{relay_operation: "resumeKillSwitchDeliveries"}

    post "/kill_switches/:kill_switch_id/cancel_paused", KillSwitchController, :cancel_paused,
      private: %{relay_operation: "cancelKillSwitchPausedDeliveries"}

    get "/virtual_clock", VirtualClockController, :show,
      private: %{relay_operation: "getVirtualClock"}

    post "/virtual_clock/advance", VirtualClockController, :advance,
      private: %{relay_operation: "advanceVirtualClock"}

    get "/test/simulated-results", SimulatedResultController, :index,
      private: %{relay_operation: "listSimulatedResults"}

    get "/inbound/whatsapp/:provider_account_id", WhatsappWebhookController, :verify,
      private: %{relay_operation: "verifyWhatsappWebhook"}

    post "/inbound/whatsapp/:provider_account_id", WhatsappWebhookController, :create,
      private: %{relay_operation: "receiveWhatsappWebhook"}

    post "/subscriber/token", SubscriberTokenController, :create,
      private: %{relay_operation: "exchangeSubscriberToken"}

    get "/subscriber/preferences", PreferenceController, :mine,
      private: %{relay_operation: "getMyPreferences"}

    patch "/subscriber/preferences", PreferenceController, :update_mine,
      private: %{relay_operation: "updateMyPreferences"}

    post "/subscriber/devices", DeviceController, :create_mine,
      private: %{relay_operation: "registerMyDevice"}

    delete "/subscriber/devices/:device_id", DeviceController, :delete_mine,
      private: %{relay_operation: "deleteMyDevice"}

    post "/subscriber/push_receipts", ReceiptController, :create_mine,
      private: %{relay_operation: "recordMyPushReceipt"}

    get "/subscriber/test_recipients", TesterController, :mine,
      private: %{relay_operation: "listMyTestRecipients"}

    post "/subscriber/test_recipients/:test_recipient_id/confirm", TesterController, :confirm,
      private: %{relay_operation: "confirmMyTestRecipient"}
  end

  # API-78
  # X-3
  scope "/v1/operator", RelayWeb.Operator do
    pipe_through :operator

    get "/session/login", SessionController, :login,
      private: %{relay_operation: "startOperatorLogin"}

    get "/session/callback", SessionController, :callback,
      private: %{relay_operation: "completeOperatorLogin"}

    get "/session", SessionController, :show, private: %{relay_operation: "getOperatorSession"}

    delete "/session", SessionController, :delete,
      private: %{relay_operation: "endOperatorSession"}

    post "/session/step_up", SessionController, :start_step_up,
      private: %{relay_operation: "startStepUp"}

    get "/session/step_up/callback", SessionController, :complete_step_up,
      private: %{relay_operation: "completeStepUp"}

    get "/roles", RoleController, :index, private: %{relay_operation: "listRoles"}

    get "/role_assignments", RoleController, :assignments,
      private: %{relay_operation: "listRoleAssignments"}

    post "/role_assignments", RoleController, :create,
      private: %{relay_operation: "createRoleAssignment"}

    post "/role_assignments/:role_assignment_id/revoke", RoleController, :revoke,
      private: %{relay_operation: "revokeRoleAssignment"}

    get "/kill_switches", PlatformController, :kill_switches,
      private: %{relay_operation: "listPlatformKillSwitches"}

    post "/kill_switches", PlatformController, :engage,
      private: %{relay_operation: "engagePlatformKillSwitch"}

    post "/kill_switches/:kill_switch_id/replace", PlatformController, :replace,
      private: %{relay_operation: "replacePlatformKillSwitch"}

    post "/kill_switches/:kill_switch_id/release", PlatformController, :release,
      private: %{relay_operation: "releasePlatformKillSwitch"}

    get "/tenants", PlatformController, :tenants, private: %{relay_operation: "listTenants"}

    get "/tenants/:tenant_id", PlatformController, :tenant,
      private: %{relay_operation: "getTenant"}

    post "/tenants/:tenant_id/suspend", PlatformController, :suspend,
      private: %{relay_operation: "suspendTenant"}

    post "/tenants/:tenant_id/resume", PlatformController, :resume,
      private: %{relay_operation: "resumeTenant"}

    get "/tenants/:tenant_id/critical_interruption", PlatformController, :critical,
      private: %{relay_operation: "getCriticalInterruption"}

    put "/tenants/:tenant_id/critical_interruption", PlatformController, :set_critical,
      private: %{relay_operation: "setCriticalInterruption"}

    get "/queue_panel", PlatformController, :queue_panel,
      private: %{relay_operation: "getQueuePanel"}

    get "/send_modes", TenantController, :send_modes, private: %{relay_operation: "listSendModes"}

    put "/send_modes", TenantController, :set_send_mode,
      private: %{relay_operation: "setSendMode"}

    get "/api_version", TenantController, :api_version,
      private: %{relay_operation: "getApiVersion"}

    put "/api_version", TenantController, :set_api_version,
      private: %{relay_operation: "setApiVersion"}

    get "/quotas", TenantController, :quotas, private: %{relay_operation: "listQuotaPolicies"}

    put "/quotas", TenantController, :set_quota, private: %{relay_operation: "setQuotaPolicy"}

    get "/support_delegations", SupportController, :delegations,
      private: %{relay_operation: "listSupportDelegations"}

    post "/support_delegations", SupportController, :grant,
      private: %{relay_operation: "grantSupportDelegation"}

    post "/support_delegations/:delegation_id/revoke", SupportController, :revoke,
      private: %{relay_operation: "revokeSupportDelegation"}

    post "/subscribers/:subscriber_id/reveal", SupportController, :reveal,
      private: %{relay_operation: "revealSubscriberPii"}

    post "/subscribers/:subscriber_id/suspend", SubscriberController, :suspend,
      private: %{relay_operation: "suspendSubscriber"}

    post "/subscribers/:subscriber_id/resume", SubscriberController, :resume,
      private: %{relay_operation: "resumeSubscriber"}

    post "/suppressions/:suppression_id/lift", SuppressionController, :lift,
      private: %{relay_operation: "liftSuppressionAsOperator"}

    post "/provider_accounts", ChannelController, :create_account,
      private: %{relay_operation: "createProviderAccount"}

    post "/provider_accounts/:provider_account_id/archive", ChannelController, :archive_account,
      private: %{relay_operation: "archiveProviderAccount"}

    post "/provider_accounts/:provider_account_id/rotate_credential",
         ChannelController,
         :rotate_credential,
         private: %{relay_operation: "rotateProviderAccountCredential"}

    post "/sender_identities/:sender_identity_id/review", ChannelController, :review_sender,
      private: %{relay_operation: "reviewSenderIdentity"}

    post "/sender_identities/:sender_identity_id/suspend", ChannelController, :suspend_sender,
      private: %{relay_operation: "suspendSenderIdentity"}

    post "/sender_identities/:sender_identity_id/resume", ChannelController, :resume_sender,
      private: %{relay_operation: "resumeSenderIdentity"}

    post "/channel_identities", ChannelController, :create_channel_identity,
      private: %{relay_operation: "createChannelIdentity"}

    post "/channel_identities/:channel_identity_id/rotate_secret",
         ChannelController,
         :rotate_secret,
         private: %{relay_operation: "rotateChannelIdentitySecret"}

    get "/audit_log", SupportController, :audit_log,
      private: %{relay_operation: "listAuditRecords"}

    get "/api_clients", SupportController, :api_clients,
      private: %{relay_operation: "listApiClients"}

    get "/api_clients/:api_client_id", SupportController, :api_client,
      private: %{relay_operation: "getApiClient"}
  end

  # X-7
  # T-87
  scope "/v1/operator" do
    pipe_through :panel

    oban_dashboard("/queues", resolver: RelayWeb.Operator.Panel, oban_name: Oban)
  end

  # API-36
  scope "/v1", RelayWeb.Api do
    match :*, "/*path", FallbackController, :not_found
  end
end
