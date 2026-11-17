defmodule RelayWeb.Auth.OperatorSession do
  @moduledoc """
  The console's operator session on server operations (X-47, X-3, X-4, TN-19 … TN-23). A server operation whose contract lists `operator_session` among its security schemes accepts the `relay_operator_session` cookie of a panel session when the request carries no `Authorization` header; a request with `Authorization: DPoP` stays on the API client path. In order:

  * the cookie resolves to an active session of an active operator (`401 auth_invalid_session` otherwise);
  * a mutating request carries the session's `Relay-Csrf-Token` (`403 auth_csrf_failed`);
  * `Relay-Tenant` and `Relay-Environment` select the tenant scope; both are required (`422 validation_failed`);
  * the operation's role (`x-relay-role`, `tenant_operator` when the contract names none) is checked by `Relay.Operators.Authz` in that scope; the installation operator outside the installation tenant reads only under an active support delegation (TN-23);
  * an operation whose step-up is `always` needs a fresh Access step-up (TN-21);
  * the session's highest role in the scope maps to the server scopes by the fixed table of `Relay.Operators.Authz.server_scopes/1`.

  The principal is of kind `:operator`; writes record the operator as their audit actor (`RelayWeb.Api.Work.actor/1`).
  """

  import Plug.Conn

  alias Relay.Operators
  alias Relay.Operators.Authz
  alias Relay.Operators.Session
  alias RelayWeb.Auth.Principal

  @cookie "relay_operator_session"
  @mutating ["POST", "PUT", "PATCH", "DELETE"]

  # X-47
  @doc "Returns true if the request uses the operator session on an operation that accepts it: the session cookie and no `Authorization` header."
  @spec present?(Plug.Conn.t(), Relay.Api.Contract.operation()) :: boolean()
  def present?(conn, %{operator_session: true}) do
    get_req_header(conn, "authorization") == [] and
      is_binary(fetch_cookies(conn).req_cookies[@cookie])
  end

  def present?(_conn, _operation), do: false

  # X-47
  # X-3
  # X-4
  # TN-21
  # TN-23
  @doc "Authenticates and authorizes the operator session of a request for a server operation."
  @spec authenticate(Plug.Conn.t(), Relay.Api.Contract.operation()) ::
          {:ok, Plug.Conn.t(), Principal.t()} | {:error, Plug.Conn.t(), Relay.Error.t()}
  def authenticate(conn, operation) do
    conn = fetch_cookies(conn)

    with {:ok, session} <- Operators.resolve(conn.req_cookies[@cookie]),
         :ok <- csrf(conn, session),
         {:ok, scope} <- context(conn),
         {:ok, delegation_id} <- authorize(conn, session, scope, operation),
         {:ok, refs} <- step_up(conn, session, operation) do
      installation = Operators.installation_tenant_id()
      role = Authz.highest(session.grants, scope, installation)

      principal = %Principal{
        kind: :operator,
        scope: scope,
        scopes: Authz.server_scopes(role || :tenant_operator),
        operator: %{
          session: session,
          role: role || :tenant_operator,
          delegation_id: delegation_id,
          step_up_refs: refs
        }
      }

      {:ok, conn, principal}
    else
      {:error, %Relay.Error{} = error} -> {:error, conn, error}
    end
  end

  defp csrf(%{method: method} = conn, %Session{client_kind: :panel} = session)
       when method in @mutating do
    with [token] <- get_req_header(conn, "relay-csrf-token"),
         digest when is_binary(digest) <- session.csrf_digest,
         true <- Plug.Crypto.secure_compare(Operators.digest(token), digest) do
      :ok
    else
      _ -> {:error, Relay.Error.new(:auth_csrf_failed, "send the session CSRF token")}
    end
  end

  defp csrf(_conn, _session), do: :ok

  # X-4
  defp context(conn) do
    case {get_req_header(conn, "relay-tenant"), get_req_header(conn, "relay-environment")} do
      {[tenant], [environment]} ->
        with {:ok, tenant_id} <- Relay.ExternalId.decode(tenant, ["ten"]),
             {:ok, environment} <- Relay.Environment.cast(environment) do
          {:ok, Relay.Scope.new!(tenant_id, environment)}
        else
          _ -> {:error, header_error("relay-tenant", "invalid_format")}
        end

      {[], _environment} ->
        {:error, header_error("relay-tenant", "required")}

      {_tenant, _environment} ->
        {:error, header_error("relay-environment", "required")}
    end
  end

  defp header_error(name, code) do
    Relay.Error.new(:validation_failed, "the tenant context headers are invalid", %{
      errors: [
        %{pointer: "/headers/" <> name, code: code, detail: "Relay-Tenant and Relay-Environment"}
      ]
    })
  end

  # TN-19
  # TN-23
  defp authorize(conn, session, scope, operation) do
    installation = Operators.installation_tenant_id()

    context = %{
      installation_tenant_id: installation,
      scope: scope,
      delegation_id: delegation(session, scope, installation),
      reads?: conn.method == "GET",
      reveal?: false,
      installation_allowed?: false
    }

    case Authz.authorize(session.grants, operation.role || :tenant_operator, context) do
      {:ok, :own} ->
        {:ok, nil}

      {:ok, {:delegated, id}} ->
        {:ok, id}

      {:error, :delegation_required, _details} ->
        {:error, Relay.Error.new(:auth_delegation_required, "support access needs a delegation")}

      {:error, :insufficient_role, %{required: required, granted: granted}} ->
        {:error,
         Relay.Error.new(:auth_insufficient_role, "the operator lacks the role", %{
           required_role: Atom.to_string(required),
           granted_roles: Enum.map(granted, &Atom.to_string/1)
         })}
    end
  end

  defp delegation(session, scope, installation) do
    if scope.tenant_id != installation and
         Authz.installation_operator?(session.grants, installation) do
      case Operators.delegation_active(session.operator_id, scope) do
        %{"delegation_id" => id} -> id
        nil -> nil
      end
    end
  end

  # TN-21
  # E-27
  defp step_up(conn, session, %{step_up: :always} = operation),
    do: Operators.step_up(session, operation.id, conn.request_path)

  defp step_up(_conn, _session, _operation), do: {:ok, nil}

  # TN-21
  # TN-22
  @doc "Requires a fresh step-up of the request's operator for a conditionally sensitive change; returns the principal with its step-up references."
  @spec require_step_up(Principal.t(), Relay.Api.Contract.operation(), String.t()) ::
          {:ok, Principal.t()} | {:error, Relay.Error.t()}
  def require_step_up(%Principal{operator: %{step_up_refs: %{}}} = principal, _operation, _path),
    do: {:ok, principal}

  def require_step_up(%Principal{operator: operator} = principal, operation, path) do
    case Operators.step_up(operator.session, operation.id, path) do
      {:ok, refs} -> {:ok, %{principal | operator: %{operator | step_up_refs: refs}}}
      {:error, error} -> {:error, error}
    end
  end

  # TN-21
  @doc "The `auth_step_up_required` error with its RFC 9470 challenge."
  @spec step_up_required() :: Relay.Error.t()
  defdelegate step_up_required(), to: Operators

  # TN-22
  @doc "Returns true if the operator's session holds a fresh step-up, so a change that may relax can carry it."
  @spec step_up_fresh?(Principal.t()) :: boolean()
  def step_up_fresh?(%Principal{operator: %{session: session}}),
    do: Operators.step_up_fresh?(session)

  # TN-48
  # X-47
  @doc "The audit actor of an operator principal: the operator's Access subject, on behalf of its support delegation when it acts under one, with the Access record of its step-up or session."
  @spec actor(Principal.t()) :: Relay.Actor.t()
  def actor(%Principal{operator: operator}) do
    Operators.actor(operator.session,
      delegation: operator.delegation_id,
      access_record_ref: step_up_ref(operator)
    )
  end

  @doc "The step-up reference of an operator principal's request, or nil."
  @spec step_up_ref(Principal.t() | Principal.operator()) :: String.t() | nil
  def step_up_ref(%Principal{operator: operator}), do: step_up_ref(operator)
  def step_up_ref(%{step_up_refs: %{step_up_ref: ref}}), do: ref
  def step_up_ref(_operator), do: nil
end
