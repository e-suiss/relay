defmodule RelayWeb.Auth do
  @moduledoc """
  Authentication of the server API (API-41 … API-47, E-93). The plug reads the `Authorization: DPoP` Access access token and its `DPoP` proof header, asks the configured verifier (`config :relay, RelayWeb.Auth, verifier: module`) for its principal, and enforces the operation's contract: any one of its `x-relay-scopes`, and a `test`-only operation only for a `test` credential. There is no bearer Access token.

  * No credential or no proof is `401 auth_missing_credentials`, a malformed one (another scheme, more than one proof) `401 auth_malformed_credentials`; every 401 of a server operation carries a `WWW-Authenticate: DPoP` challenge.
  * Invalid credentials are limited per client IP (`throttle_invalid/1`); past the limit the answer is `429 rate_limited`.
  * A missing scope is `403 auth_insufficient_scope` with `required_scope` and `granted_scopes`; the other environment's operation is `403 auth_environment_mismatch`.
  * `Relay-Tenant` and `Relay-Environment` belong to operator sessions; with an API client credential they are `422 validation_failed`.
  * A subscriber operation accepts only a Relay subscriber token as `Authorization: Bearer` (`RelayWeb.Auth.Subscriber`); its principal names the subscriber, and the token of a suspended subscriber is `403 auth_subscriber_suspended`.

  The verifier (`RelayWeb.Auth.Access` in production) receives the operation, the proof, the request's method and external URL (`RelayWeb.Api.Transport.request_url/2`), the client address and the request's client certificate (`RelayWeb.Api.Transport.client_certificate/2`: the connection's own, or the RFC 9440 `Client-Cert` of a configured proxy). A provider webhook (`:provider_webhook`, Meta's `X-Hub-Signature-256`) needs its signature header here; its controller verifies it over the raw body with the provider account's secret.
  """

  @behaviour Plug

  import Plug.Conn

  alias Relay.Api.RateLimit
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Transport
  alias RelayWeb.Auth.Principal

  @bearer ~r/\A[Bb]earer +([A-Za-z0-9\-._~+\/]+=*)\z/
  @dpop ~r/\ADPoP +([A-Za-z0-9\-._~+\/]+=*)\z/i
  @counted [:auth_invalid_token, :auth_malformed_credentials]
  @operator_headers ["relay-tenant", "relay-environment"]

  @doc "Verifies an access token for the operation in `context` (`%{operation: operation, proof: dpop, method: method, url: url, ip: address, certificate: der | nil}`)."
  @callback verify(token :: String.t(), context :: map()) ::
              {:ok, Principal.t()} | {:error, Relay.Error.t()}

  @impl Plug
  def init(opts), do: opts

  # API-43
  # API-47
  @impl Plug
  def call(conn, _opts) do
    case authenticate(conn, conn.assigns.operation) do
      {:ok, conn} -> conn
      {:error, conn, error} -> Response.problem(conn, error)
    end
  end

  # API-42
  # API-43
  # API-47
  # API-76 (2)
  @doc "Authenticates a request for an operation; a public operation needs no credential."
  @spec authenticate(Plug.Conn.t(), Relay.Api.Contract.operation()) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t(), Relay.Error.t()}
  def authenticate(conn, %{public: true}), do: {:ok, assign(conn, :principal, nil)}

  def authenticate(conn, %{security: :provider_webhook}) do
    if get_req_header(conn, "x-hub-signature-256") != [],
      do: {:ok, assign(conn, :principal, nil)},
      else: {:error, conn, Relay.Error.new(:auth_missing_credentials, "the webhook is unsigned")}
  end

  def authenticate(conn, %{family: :subscriber} = operation) do
    with {:ok, token} <- credential(conn, @bearer, "send a Relay subscriber token as Bearer"),
         {:ok, principal} <- subscriber(conn, token),
         :ok <- operator_headers(conn),
         :ok <- scopes(principal, operation) do
      {:ok, conn |> assign(:principal, principal) |> assign(:scope, principal.scope)}
    else
      {:error, error} -> {:error, conn, error}
    end
  end

  def authenticate(conn, operation) do
    with {:ok, token} <- credential(conn, @dpop, "send an Access token as DPoP"),
         {:ok, proof} <- proof(conn),
         {:ok, principal} <- verify(conn, token, proof, operation),
         :ok <- operator_headers(conn),
         :ok <- environment(principal, operation),
         :ok <- scopes(principal, operation) do
      {:ok, conn |> assign(:principal, principal) |> assign(:scope, principal.scope)}
    else
      {:error, error} -> {:error, conn, error}
    end
  end

  defp credential(conn, scheme, missing) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, Relay.Error.new(:auth_missing_credentials, missing)}

      [value] ->
        case Regex.run(scheme, value) do
          [_, token] -> {:ok, token}
          nil -> malformed(conn, "the Authorization header is malformed")
        end

      _many ->
        malformed(conn, "the Authorization header is malformed")
    end
  end

  # E-93
  defp proof(conn) do
    case get_req_header(conn, "dpop") do
      [] -> {:error, Relay.Error.new(:auth_missing_credentials, "send a DPoP proof")}
      [proof] -> {:ok, proof}
      _many -> malformed(conn, "send one DPoP proof")
    end
  end

  defp malformed(conn, message),
    do: throttled(conn, Relay.Error.new(:auth_malformed_credentials, message))

  defp verify(conn, token, proof, operation) do
    context = %{
      operation: operation,
      proof: proof,
      method: conn.method,
      url: Transport.request_url(conn),
      ip: Transport.client_ip(conn),
      certificate: Transport.client_certificate(conn)
    }

    case verifier().verify(token, context) do
      {:ok, %Principal{} = principal} -> {:ok, principal}
      {:error, %Relay.Error{code: code} = error} when code in @counted -> throttled(conn, error)
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  # API-45
  # E-25
  # TN-73
  defp subscriber(conn, token) do
    case RelayWeb.Auth.Subscriber.verify(token) do
      {:ok, verified} ->
        {:ok,
         %Principal{
           scope: verified.scope,
           scopes: verified.scopes,
           subscriber_id: verified.subscriber_id
         }}

      {:error, %Relay.Error{code: code} = error} when code in @counted ->
        throttled(conn, error)

      {:error, %Relay.Error{} = error} ->
        {:error, error}
    end
  end

  defp throttled(conn, error) do
    case throttle_invalid(conn) do
      :ok -> {:error, error}
      {:error, limited} -> {:error, limited}
    end
  end

  # API-47
  # API-77 (3)
  @doc "Counts one invalid credential of the request's client IP; past the limit it returns `rate_limited`."
  @spec throttle_invalid(Plug.Conn.t()) :: :ok | {:error, Relay.Error.t()}
  def throttle_invalid(conn) do
    RateLimit.check_ip(
      Relay.Datasets.installation_scope(),
      :invalid_token,
      Transport.client_ip(conn)
    )
  end

  defp operator_headers(conn) do
    case Enum.filter(@operator_headers, &(get_req_header(conn, &1) != [])) do
      [] ->
        :ok

      names ->
        {:error,
         Relay.Error.new(:validation_failed, "operator session headers are not allowed", %{
           errors: Enum.map(names, &%{pointer: "/headers/" <> &1, code: "not_allowed"})
         })}
    end
  end

  defp environment(%Principal{scope: %{environment: :live}}, %{environment: :test}),
    do: {:error, Relay.Error.new(:auth_environment_mismatch, "this operation is test only")}

  defp environment(_principal, _operation), do: :ok

  defp scopes(_principal, %{scopes: []}), do: :ok

  defp scopes(%Principal{scopes: granted}, %{scopes: [required | _] = accepted}) do
    if Enum.any?(accepted, &(&1 in granted)) do
      :ok
    else
      {:error,
       Relay.Error.new(:auth_insufficient_scope, "the API client lacks the scope", %{
         required_scope: required,
         granted_scopes: granted
       })}
    end
  end

  @doc "The configured verifier module."
  @spec verifier() :: module()
  def verifier,
    do:
      :relay
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:verifier, RelayWeb.Auth.Unconfigured)
end
