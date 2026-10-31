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
