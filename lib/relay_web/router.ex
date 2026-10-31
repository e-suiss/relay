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

  scope "/", RelayWeb do
    pipe_through :api

    get "/livez", HealthController, :live
    get "/readyz", HealthController, :ready
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

    post "/access/events", AccessEventController, :create,
      private: %{relay_operation: "receiveAccessEvent"}

    post "/subscriber/token", SubscriberTokenController, :create,
      private: %{relay_operation: "exchangeSubscriberToken"}
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
