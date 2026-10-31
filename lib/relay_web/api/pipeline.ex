defmodule RelayWeb.Api.Pipeline do
  @moduledoc """
  The common request rules of every `/v1` operation, in order: the operation's contract (`Relay.Api.Contract`, named by the route's `:relay_operation`), HTTPS (API-8), `Relay-Version` (API-52) and `Relay-Beta` (API-55), authentication and scope (`RelayWeb.Auth`), the body (JSON in UTF-8 only, size limits, strict decoding; API-8), the tenant's status and pinned version, the API rate limit (API-49, API-50), the idempotency key (API-10, API-11) and request schema validation (API-8, API-37). Each step either passes or answers with a problem; nothing after a failed step runs.

  The response always carries `Request-Id`, `Relay-Version` and HSTS. A tenant without a pinned version is pinned, in a short transaction of its own, after its first successful response.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Relay.Api.Contract
  alias Relay.Api.RateLimit
  alias Relay.Api.Schema
  alias Relay.Api.Tenant
  alias Relay.Api.Versions
  alias RelayWeb.Api.Beta
  alias RelayWeb.Api.DerivedKey
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Transport

  @limits Contract.limits()
  @batch_body_bytes @limits["batch"]["max_body_bytes"]
  @body_bytes 1_048_576

  @impl Plug
  def init(opts), do: opts

  # API-8
  # API-9
  @impl Plug
  def call(conn, _opts) do
    conn =
      conn
      |> fetch_query_params()
      |> put_resp_header("strict-transport-security", Transport.hsts())
      |> put_resp_header("relay-version", Versions.latest())

    try do
      case run(conn) do
        {:ok, conn} -> conn
        {:error, conn, error} -> Response.problem(conn, error)
      end
    rescue
      exception -> Response.exception(conn, exception, __STACKTRACE__)
    end
  end

  defp run(conn) do
    with {:ok, conn} <- operation(conn),
         {:ok, conn} <- transport(conn),
         {:ok, conn} <- version(conn),
         {:ok, conn} <- beta(conn),
         {:ok, conn} <- RelayWeb.Auth.authenticate(conn, conn.assigns.operation),
         {:ok, conn} <- body(conn),
         {:ok, conn} <- tenant(conn),
         {:ok, conn} <- rate_limit(conn),
         {:ok, conn} <- idempotency_key(conn) do
      validate(conn)
    end
  end

  # API-8
  defp transport(conn) do
    case Transport.scheme(conn) do
      :https -> {:ok, conn}
      :http -> {:error, conn, Relay.Error.new(:malformed_request, "the API is served over HTTPS")}
    end
  end

  defp operation(conn) do
    operation = Contract.operation!(Map.fetch!(conn.private, :relay_operation))
    conn = assign(conn, :operation, operation)

    if operation.no_store,
      do: {:ok, put_resp_header(conn, "cache-control", "no-store")},
      else: {:ok, conn}
  end

  # API-52
  defp version(conn) do
    case get_req_header(conn, "relay-version") do
      [] ->
        {:ok, assign(conn, :requested_version, nil)}

      [value | _] ->
        case Versions.parse(value) do
          {:ok, version} -> {:ok, assign(conn, :requested_version, version)}
          {:error, error} -> {:error, conn, error}
        end
    end
  end

  # API-55
  defp beta(conn) do
    case Beta.parse(get_req_header(conn, "relay-beta")) do
      {:ok, features} -> {:ok, assign(conn, :beta_features, features)}
      {:error, error} -> {:error, conn, error}
    end
  end

  # API-8
  defp body(%{assigns: %{operation: %{request: request}}} = conn) when request == %{},
    do: {:ok, conn |> assign(:raw_body, "") |> assign(:body, nil)}

  defp body(conn) do
    operation = conn.assigns.operation
    limit = if operation.weight == :rows, do: @batch_body_bytes, else: @body_bytes

    with {:ok, media} <- media_type(conn, operation),
         {:ok, raw, conn} <- read(conn, limit),
         {:ok, decoded} <- decode(media, raw) do
      {:ok,
       conn
       |> assign(:media_type, media)
       |> assign(:raw_body, raw)
       |> assign(:body, decoded)}
    else
      {:error, %Plug.Conn{} = conn, error} -> {:error, conn, error}
      {:error, error} -> {:error, conn, error}
    end
  end

  defp media_type(conn, operation) do
    with [value] <- get_req_header(conn, "content-type"),
         {:ok, type, subtype, params} <- Plug.Conn.Utils.content_type(value),
         media = type <> "/" <> subtype,
         true <- Map.has_key?(operation.request, media),
         true <- String.downcase(Map.get(params, "charset", "utf-8")) == "utf-8" do
      {:ok, media}
    else
      _ ->
        {:error,
         Relay.Error.new(:unsupported_media_type, "send JSON in UTF-8 with a supported type")}
    end
  end

  defp read(conn, limit) do
    declared =
      case get_req_header(conn, "content-length") do
        [value] -> value |> Integer.parse() |> elem_or_nil()
        _ -> nil
      end

    if is_integer(declared) and declared > limit do
      {:error, conn, too_large(limit, declared)}
    else
      case read_body(conn, length: limit) do
        {:ok, raw, conn} -> {:ok, raw, conn}
        {:more, _partial, conn} -> {:error, conn, too_large(limit, nil)}
        {:error, _reason} -> {:error, conn, malformed("the body could not be read")}
      end
    end
  end

  defp elem_or_nil({n, ""}), do: n
  defp elem_or_nil(_parsed), do: nil

  defp too_large(limit, actual) do
    Relay.Error.new(:payload_too_large, "the body exceeds #{limit} bytes", %{
      limit: limit,
      actual: actual,
      limit_name: "body_bytes"
    })
  end

  defp decode(_media, ""), do: {:error, malformed("the body is empty")}

  defp decode("application/x-www-form-urlencoded", raw) do
    {:ok, Plug.Conn.Query.decode(raw)}
  rescue
    Plug.Conn.InvalidQueryError -> {:error, malformed("the form body is not valid")}
  end

  defp decode(_media, raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _error} -> {:error, malformed("the body is not valid JSON")}
    end
  end

  defp malformed(detail), do: Relay.Error.new(:malformed_request, detail)

  # API-47
  # API-52
  # API-54
  defp tenant(%{assigns: %{principal: nil}} = conn) do
    {version, _source} = Versions.resolve(conn.assigns.requested_version, nil)
    {:ok, served(conn, version)}
  end

  defp tenant(conn) do
    case Tenant.edge(conn.assigns.scope) do
      {:ok, %{status: :active} = edge} ->
        active(conn, edge)

      {:ok, _inactive} ->
        {:error, conn, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      {:error, error} ->
        {:error, conn, error}
    end
  end

  # API-41
  # API-48
  defp active(conn, edge) do
    if edge.mtls_required and not conn.assigns.principal.certificate_bound do
      {:error, conn, Relay.Error.new(:auth_invalid_token, "a certificate-bound token is needed")}
    else
      {version, source} = Versions.resolve(conn.assigns.requested_version, edge.api_version)
      conn = conn |> assign(:tenant, edge) |> served(version)
      {:ok, if(source == :pin, do: pin_after_success(conn, version), else: conn)}
    end
  end

  defp served(conn, version) do
    conn
    |> assign(:api_version, version)
    |> put_resp_header("relay-version", version)
    |> merge_resp_headers(Versions.headers(version))
  end

  defp pin_after_success(conn, version) do
    %{scope: scope, principal: principal} = conn.assigns

    register_before_send(conn, fn conn ->
      if conn.status in 200..299, do: pin(scope, version, principal)
      conn
    end)
  end

  defp pin(scope, version, principal) do
    ref = principal.api_client_id || "unknown"
    {:ok, actor} = Relay.Actor.new(:api_client, ref, ref)

    case Tenant.pin(scope, version, actor) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("API version pin failed", reason: inspect(reason))
    end
  rescue
    exception -> Logger.warning("API version pin failed", reason: Exception.message(exception))
  end

  # API-49
  # API-50
  # API-77
  defp rate_limit(%{assigns: %{principal: nil, operation: %{security: :webhook}}} = conn),
    do: {:ok, conn}

  defp rate_limit(%{assigns: %{principal: nil, operation: %{public: true} = operation}} = conn) do
    ip = Transport.client_ip(conn)
    kind = if operation.family == :subscriber, do: :token_exchange, else: :error_pages

    case RateLimit.check_ip(Relay.Datasets.installation_scope(), kind, ip) do
      :ok -> {:ok, conn}
      {:error, error} -> {:error, conn, error}
    end
  end

  defp rate_limit(conn) do
    %{principal: principal, tenant: tenant, operation: operation} = conn.assigns
    tiers = RateLimit.tiers(tenant.rate_settings, client(principal))

    case RateLimit.check(principal.scope, tiers, cost(operation.weight, conn.assigns.body)) do
      {:ok, report} -> {:ok, rate_headers(conn, report)}
      {:error, error, report} -> {:error, rate_headers(conn, report), error}
    end
  end

  defp client(%{rate_limit: nil}), do: nil
  defp client(principal), do: %{id: principal.api_client_id, tiers: principal.rate_limit}

  defp cost(:rows, body) when is_map(body) do
    body
    |> Map.values()
    |> Enum.filter(&is_list/1)
    |> Enum.map(&length/1)
    |> Enum.sum()
    |> max(1)
  end

  defp cost(:rows, _body), do: 1
  defp cost(weight, _body), do: weight

  defp rate_headers(conn, %{current: nil}), do: conn

  defp rate_headers(conn, %{tiers: tiers, current: current}) do
    policy = Enum.map_join(tiers, ", ", &~s("#{&1.name}";q=#{&1.quota};w=#{&1.window_s}))

    merge_resp_headers(conn, [
      {"ratelimit", ~s("#{current.name}";r=#{current.remaining};t=#{current.reset_s})},
      {"ratelimit-policy", policy},
      {"x-ratelimit-limit", Integer.to_string(current.quota)},
      {"x-ratelimit-remaining", Integer.to_string(current.remaining)},
      {"x-ratelimit-reset", Integer.to_string(current.reset_s)}
    ])
  end

  # API-10
  # API-11
  defp idempotency_key(conn) do
    mode = conn.assigns.operation.idempotency
    headers = get_req_header(conn, "idempotency-key")

    case Relay.Api.Idempotency.key(mode, headers, fn -> DerivedKey.key(conn) end) do
      {:ok, key} -> {:ok, assign(conn, :idempotency_key, key)}
      {:error, error} -> {:error, conn, error}
    end
  end

  # API-8
  # API-37
  # API-54
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
