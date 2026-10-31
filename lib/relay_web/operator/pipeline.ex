defmodule RelayWeb.Operator.Pipeline do
  @moduledoc """
  The request rules of every `/v1/operator` operation, in order: the operation's contract, HTTPS, `Relay-Version` and `Relay-Beta`, the operator's authentication (the `relay_operator_session` cookie of a panel session, or the CLI's Access access token as `Authorization: Bearer`), CSRF for cookie-authenticated mutating requests (`Relay-Csrf-Token`), the tenant context (`Relay-Tenant`, `Relay-Environment`), the operation's role (`Relay.Operators.Authz`), the step-up of an operation that always needs one, the body and its schema, and the idempotency key. Each step passes or answers with a problem.

  Assigns: `:operation`, `:operator_session`, `:operator_scope` (the selected tenant scope, `nil` outside one), `:delegation_id`, `:scope` (the scope idempotency records are kept in), `:step_up_refs`, `:body`, `:raw_body` and `:idempotency_key`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Relay.Api.Contract
  alias Relay.Api.Schema
  alias Relay.Api.Versions
  alias Relay.Operators
  alias Relay.Operators.Authz
  alias Relay.Operators.Session
  alias RelayWeb.Api.Beta
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Transport

  @cookie "relay_operator_session"
  @bearer ~r/\A[Bb]earer +([A-Za-z0-9\-._~+\/]+=*)\z/
  @mutating ["POST", "PUT", "PATCH", "DELETE"]
  @body_bytes 1_048_576

  @impl Plug
  def init(opts), do: opts

  # X-3
  # TN-19
  @impl Plug
  def call(conn, _opts) do
    conn =
      conn
      |> fetch_query_params()
      |> fetch_cookies()
      |> secret_key_base()
      |> put_resp_header("strict-transport-security", Transport.hsts())
      |> put_resp_header("relay-version", Versions.latest())
      |> put_resp_header("cache-control", "no-store")

    try do
      case run(conn) do
        {:ok, conn} -> conn
        {:error, conn, error} -> Response.problem(conn, error)
      end
    rescue
      exception -> Response.exception(conn, exception, __STACKTRACE__)
    end
  end

  @doc "The name of the panel session cookie."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  defp secret_key_base(%{secret_key_base: nil} = conn) do
    %{conn | secret_key_base: RelayWeb.Endpoint.config(:secret_key_base)}
  rescue
    ArgumentError ->
      configured = Application.get_env(:relay, RelayWeb.Endpoint, [])[:secret_key_base]
      %{conn | secret_key_base: configured}
  end

  defp secret_key_base(conn), do: conn

  defp run(conn) do
    with {:ok, conn} <- operation(conn),
         {:ok, conn} <- transport(conn),
         {:ok, conn} <- version(conn),
         {:ok, conn} <- beta(conn),
         {:ok, conn} <- authenticate(conn),
         {:ok, conn} <- csrf(conn),
         {:ok, conn} <- context(conn),
         {:ok, conn} <- authorize(conn),
         {:ok, conn} <- step_up(conn),
         {:ok, conn} <- body(conn),
         {:ok, conn} <- idempotency_key(conn) do
      validate(conn)
    end
  end

  defp operation(conn) do
    id = Map.fetch!(conn.private, :relay_operation)
    {:ok, conn |> assign(:operation, Contract.operation!(id)) |> assign(:api_version, nil)}
  end

  defp transport(conn) do
    case Transport.scheme(conn) do
      :https -> {:ok, conn}
      :http -> {:error, conn, Relay.Error.new(:malformed_request, "the API is served over HTTPS")}
    end
  end

  defp version(conn) do
    case get_req_header(conn, "relay-version") do
      [] ->
        {:ok, assign(conn, :api_version, Versions.latest())}

      [value | _] ->
        case Versions.parse(value) do
          {:ok, version} ->
            {:ok,
             conn |> assign(:api_version, version) |> put_resp_header("relay-version", version)}

          {:error, error} ->
            {:error, conn, error}
        end
    end
  end

  defp beta(conn) do
    case Beta.parse(get_req_header(conn, "relay-beta")) do
      {:ok, features} -> {:ok, assign(conn, :beta_features, features)}
      {:error, error} -> {:error, conn, error}
    end
  end

  # TN-19
  # TN-20
  defp authenticate(%{assigns: %{operation: %{public: true}}} = conn),
    do: {:ok, assign(conn, :operator_session, nil)}

  defp authenticate(conn) do
    result =
      case get_req_header(conn, "authorization") do
        [value] -> bearer(value)
        [] -> cookie_session(conn.req_cookies[@cookie])
        _many -> {:error, malformed()}
      end

    case result do
      {:ok, %Session{} = session} -> {:ok, assign(conn, :operator_session, session)}
      {:error, error} -> {:error, conn, error}
    end
  end

  defp bearer(value) do
    case Regex.run(@bearer, value) do
      [_, token] -> Operators.resolve_bearer(token)
      nil -> {:error, malformed()}
    end
  end

  defp cookie_session(token) when is_binary(token) and token != "", do: Operators.resolve(token)

  defp cookie_session(_token),
    do: {:error, Relay.Error.new(:auth_missing_credentials, "sign in through Access")}

  defp malformed, do: Relay.Error.new(:auth_malformed_credentials, "malformed credentials")

  defp csrf(
         %{method: method, assigns: %{operator_session: %Session{client_kind: :panel} = session}} =
           conn
       )
       when method in @mutating do
    with [token] <- get_req_header(conn, "relay-csrf-token"),
         true <- Plug.Crypto.secure_compare(Operators.digest(token), session.csrf_digest) do
      {:ok, conn}
    else
      _ -> {:error, conn, Relay.Error.new(:auth_csrf_failed, "send the session CSRF token")}
    end
  end

  defp csrf(conn), do: {:ok, conn}

  # X-4
  defp context(%{assigns: %{operation: %{public: true}}} = conn),
    do: {:ok, conn |> assign(:operator_scope, nil) |> assign(:scope, nil)}

  defp context(conn) do
    case {get_req_header(conn, "relay-tenant"), get_req_header(conn, "relay-environment")} do
      {[], []} ->
        scope = if tenant_operation?(conn), do: :missing, else: nil
        selected(conn, scope)

      {[tenant], [environment]} ->
        with {:ok, tenant_id} <- Relay.ExternalId.decode(tenant, ["ten"]),
             {:ok, environment} <- Relay.Environment.cast(environment) do
          selected(conn, Relay.Scope.new!(tenant_id, environment))
        else
          _ -> {:error, conn, header_error("relay-tenant", "invalid_format")}
        end

      {[], _environment} ->
        {:error, conn, header_error("relay-tenant", "required")}

      {_tenant, _environment} ->
        {:error, conn, header_error("relay-environment", "required")}
    end
  end

  defp tenant_operation?(conn),
    do: conn.assigns.operation.role in [:tenant_admin, :tenant_operator]

  defp selected(conn, :missing), do: {:error, conn, header_error("relay-tenant", "required")}

  defp selected(conn, scope) do
    storage = scope || Operators.installation_scope()
    {:ok, conn |> assign(:operator_scope, scope) |> assign(:scope, storage)}
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
  defp authorize(%{assigns: %{operation: %{public: true}}} = conn),
    do: {:ok, assign(conn, :delegation_id, nil)}

  defp authorize(conn) do
    %{operation: operation, operator_session: session, operator_scope: scope} = conn.assigns
    installation = Operators.installation_tenant_id()

    context = %{
      installation_tenant_id: installation,
      scope: scope,
      delegation_id: delegation(session, scope, installation),
      reads?: conn.method == "GET",
      reveal?: operation.id == "revealSubscriberPii"
    }

    case Authz.authorize(session.grants, operation.role, context) do
      {:ok, :own} ->
        {:ok, assign(conn, :delegation_id, nil)}

      {:ok, {:delegated, id}} ->
        {:ok, assign(conn, :delegation_id, id)}

      {:error, :delegation_required, _details} ->
        {:error, conn,
         Relay.Error.new(:auth_delegation_required, "support access needs a delegation")}

      {:error, :insufficient_role, %{required: required, granted: granted}} ->
        {:error, conn,
         Relay.Error.new(:auth_insufficient_role, "the operator lacks the role", %{
           required_role: Atom.to_string(required),
           granted_roles: Enum.map(granted, &Atom.to_string/1)
         })}
    end
  end

  defp delegation(%Session{} = session, %Relay.Scope{} = scope, installation) do
    if scope.tenant_id != installation and
         Authz.installation_operator?(session.grants, installation) do
      case Operators.delegation_active(session.operator_id, scope) do
        %{"delegation_id" => id} -> id
        nil -> nil
      end
    end
  end

  defp delegation(_session, _scope, _installation), do: nil

  # TN-21
  # E-27
  defp step_up(%{assigns: %{operation: %{step_up: :always} = operation}} = conn) do
    case Operators.step_up(conn.assigns.operator_session, operation.id, conn.request_path) do
      {:ok, refs} -> {:ok, assign(conn, :step_up_refs, refs)}
      {:error, error} -> {:error, conn, error}
    end
  end

  defp step_up(conn), do: {:ok, assign(conn, :step_up_refs, nil)}

  defp body(%{assigns: %{operation: %{request: request}}} = conn) when request == %{},
    do: {:ok, conn |> assign(:raw_body, "") |> assign(:body, nil)}

  defp body(conn) do
    case read_body(conn, length: @body_bytes) do
      {:ok, "", conn} ->
        {:ok, conn |> assign(:raw_body, "") |> assign(:body, %{}) |> assign(:media_type, json())}

      {:ok, raw, conn} ->
        with {:ok, media} <- media_type(conn),
             {:ok, decoded} <- decode(raw) do
          {:ok,
           conn |> assign(:raw_body, raw) |> assign(:body, decoded) |> assign(:media_type, media)}
        else
          {:error, error} -> {:error, conn, error}
        end

      {:more, _partial, conn} ->
        {:error, conn,
         Relay.Error.new(:payload_too_large, "the body exceeds #{@body_bytes} bytes", %{
           limit: @body_bytes,
           limit_name: "body_bytes"
         })}

      {:error, _reason} ->
        {:error, conn, Relay.Error.new(:malformed_request, "the body could not be read")}
    end
  end

  defp json, do: "application/json"

  defp media_type(conn) do
    with [value] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", params} <- Plug.Conn.Utils.content_type(value),
         true <- String.downcase(Map.get(params, "charset", "utf-8")) == "utf-8" do
      {:ok, json()}
    else
      _ -> {:error, Relay.Error.new(:unsupported_media_type, "send JSON in UTF-8")}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _error} -> {:error, Relay.Error.new(:malformed_request, "the body is not JSON")}
    end
  end

  defp idempotency_key(conn) do
    mode = conn.assigns.operation.idempotency
    headers = get_req_header(conn, "idempotency-key")

    case Relay.Api.Idempotency.key(mode, headers, fn -> :none end) do
      {:ok, key} -> {:ok, assign(conn, :idempotency_key, key)}
      {:error, error} -> {:error, conn, error}
    end
  end

  defp validate(%{assigns: %{operation: %{request: request}}} = conn) when request == %{},
    do: {:ok, conn}

  defp validate(conn) do
    %{operation: operation, media_type: media, body: body, api_version: version} = conn.assigns

    case Schema.validate_request(operation.id, media, body) do
      :ok -> {:ok, assign(conn, :body, Versions.request(version, operation.id, body))}
      {:error, error} -> {:error, conn, error}
    end
  end
end
