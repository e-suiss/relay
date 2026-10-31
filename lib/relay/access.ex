defmodule Relay.Access do
  @moduledoc """
  The link to Access, Suiss's identity and authority product (MD-1, E-1 … E-5, E-40, E-78). Relay always runs with Access and is never an authority source. The link is configured with one value, the Access `issuer` (`config :relay, Relay.Access, issuer: "https://…"`); endpoints, keys and capabilities come from discovery (`Relay.Access.Link`). Other contexts use only the functions of this module.

  * Server API credentials are Access client credentials tokens (API-41, API-48, API-71): `verify_server_token/2` checks them on every request and maps the API client trace to its tenant, environment, sub-tenant and API-75 scopes.
  * An ingest connector acts as an API client trace of its configuration (`connector_principal/2`, T-41), checked like a server token.
  * API client traces, tenant and sub-tenant mappings follow Access lifecycle events (`accept_event/1`, `process_event/1`).
  * Subscriber tokens come only from the RFC 8693 exchange (`exchange_subscriber_token/2`) and are checked with `verify_subscriber_token/2`; an Access token is never a subscriber credential (E-25).
  * Platform tenants (`message_class/2`, `dedup_key/2`) and sub-tenant selection (`select_subtenant/3`).
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Platform.Leadership,
      Relay.Tenancy,
      Relay.Tenancy.Provisioning
    ],
    exports: [UserHandler]

  alias Relay.Access.Clients
  alias Relay.Access.ClientStore
  alias Relay.Access.Events
  alias Relay.Access.Link
  alias Relay.Access.PlatformTenant
  alias Relay.Access.SubscriberToken
  alias Relay.Access.Token
  alias Relay.Access.Usage
  alias Relay.Scope

  @scopes ~w(publish read subscribers config kill_switch)
  @client_cap 50
  @unused_days 90

  @type principal :: %{
          scope: Scope.t(),
          scopes: [String.t()],
          subtenant_id: Relay.Id.t() | nil,
          api_client_id: String.t(),
          certificate_bound: boolean()
        }

  @doc "The `Relay.Access` configuration."
  @spec config() :: keyword()
  def config, do: Application.get_env(:relay, __MODULE__, [])

  # E-78
  @doc "The configured Access issuer, the link's only configuration value."
  @spec issuer() :: String.t() | nil
  def issuer, do: Keyword.get(config(), :issuer)

  @doc "Supervised children: the link snapshot, the API client cache and the usage writer."
  @spec children() :: [module()]
  def children, do: [Link, Clients, Usage]

  # E-75
  @doc "The node's link state: `:ok`, `:stale`, `:pending`, `:region_mismatch`, or `:unknown` while the link process is not running."
  @spec link_state() :: Link.state() | :unknown
  def link_state do
    case Link.current() do
      %{state: state} -> state
      :unknown -> :unknown
    end
  end

  # E-5
  # E-78
  # INV-41
  @doc "Fetches and records the Access discovery documents and keys now; see `Relay.Access.Link.refresh/1`."
  @spec refresh(keyword()) :: {:ok, :ok} | {:error, Relay.Error.t()}
  def refresh(opts \\ []), do: Link.refresh(opts)

  # API-41
  # API-42
  # API-43
  # API-44
  # API-47
  # API-48
  # API-71
  # API-75
  # TN-24
  @doc """
  Verifies an Access client credentials token for the server API. Options: `:audience` (required, the Relay server API), `:ip` (the client address, for last use) and `:certificate` (the DER client certificate of the connection, for RFC 8705 binding).

  The token names its Access tenant (`tenant_id`) and client (`client_id`); tenant, environment and sub-tenant come from the API client trace, never from the request. The granted scopes are the trace's API-75 scopes that the token also carries. A revoked or suspended client is `auth_revoked_client`, a suspended tenant or sub-tenant `auth_tenant_suspended`, a link without keys `service_unavailable`. A token bound to a certificate (`cnf.x5t#S256`) needs that certificate.
  """
  @spec verify_server_token(String.t(), keyword()) ::
          {:ok, principal()} | {:error, Relay.Error.t()}
  def verify_server_token(token, opts) do
    audience = Keyword.fetch!(opts, :audience)

    with {:ok, claims} <- verified(token, audience),
         {:ok, resolved} <- client(claims),
         :ok <- active(resolved),
         {:ok, bound} <- binding(claims, Keyword.get(opts, :certificate)),
         {:ok, scope} <- Scope.new(resolved.tenant_id, resolved.environment) do
      :ok = Usage.note(scope, resolved.api_client_id, Keyword.get(opts, :ip))

      {:ok,
       %{
         scope: scope,
         scopes: granted(resolved.scopes, claims),
         subtenant_id: resolved.subtenant_id,
         api_client_id: Relay.ExternalId.encode("cli", resolved.api_client_id),
         certificate_bound: bound
       }}
    end
  end

  # T-41
  # API-71
  # API-44
  # INV-42
  @doc """
  The principal an ingest connector acts as: the API client trace of an Access tenant and client, resolved and checked like a verified server token but without a token, since the connector is configured by the installation and not presented by a caller. The trace must be active and its tenant and sub-tenant active; the granted scopes are all of the trace's API-75 scopes. A connector never holds a client certificate.
  """
  @spec connector_principal(String.t(), String.t()) ::
          {:ok, principal()} | {:error, Relay.Error.t()}
  def connector_principal(access_tenant_id, access_client_id)
      when is_binary(access_tenant_id) and is_binary(access_client_id) do
    with {:ok, resolved} <-
           client(%{"tenant_id" => access_tenant_id, "client_id" => access_client_id}),
         :ok <- active(resolved),
         {:ok, scope} <- Scope.new(resolved.tenant_id, resolved.environment) do
      {:ok,
       %{
         scope: scope,
         scopes: granted(resolved.scopes, %{}),
         subtenant_id: resolved.subtenant_id,
         api_client_id: Relay.ExternalId.encode("cli", resolved.api_client_id),
         certificate_bound: false
       }}
    end
  end

  defp verified(token, audience) do
    case verify_with_link(token, audience) do
      {:error, :unknown_key} ->
        _ = Link.refresh_keys()

        case verify_with_link(token, audience) do
          {:error, :unknown_key} -> invalid("the token is signed by an unknown key")
          result -> result
        end

      result ->
        result
    end
  end

  defp verify_with_link(token, audience) do
    case Link.current() do
      %{state: state, keys: [_ | _] = keys, issuer: issuer} when state in [:ok, :stale] ->
        expectation = %{issuer: issuer, audience: audience, now: now()}
        Token.verify(token, keys, expectation)

      _no_keys ->
        {:error, Relay.Error.new(:service_unavailable, "the Access link is not established")}
    end
  end

  defp client(%{"tenant_id" => tenant, "client_id" => client})
       when is_binary(tenant) and is_binary(client) do
    case Clients.resolve(tenant, client) do
      {:ok, resolved} -> {:ok, resolved}
      :unknown -> invalid("the API client is not registered")
    end
  end

  defp client(_claims), do: invalid("the token names no Access tenant and client")

  # API-44
  # API-47
  # INV-42
  # TN-10
  defp active(%{status: "active", tenant_status: "active"}), do: :ok

  defp active(%{status: "active"}),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  defp active(_resolved),
    do: {:error, Relay.Error.new(:auth_revoked_client, "the API client is revoked or suspended")}

  # API-41
  # API-48
  defp binding(%{"cnf" => %{"x5t#S256" => thumbprint}}, certificate)
       when is_binary(thumbprint) and is_binary(certificate) do
    computed = Base.url_encode64(:crypto.hash(:sha256, certificate), padding: false)

    if Token.same?(computed, thumbprint),
      do: {:ok, true},
      else: invalid("the token is bound to another certificate")
  end

  defp binding(%{"cnf" => %{"x5t#S256" => _thumbprint}}, _certificate),
    do: invalid("the token is bound to a client certificate")

  defp binding(_claims, _certificate), do: {:ok, false}

  # API-43
  # API-75
  defp granted(scopes, %{"scope" => carried}) when is_binary(carried) do
    carried = String.split(carried, " ", trim: true)
    Enum.filter(scopes, &(&1 in carried and &1 in @scopes))
  end

  defp granted(scopes, _claims), do: Enum.filter(scopes, &(&1 in @scopes))

  # API-44
  @doc false
  @spec touch(Scope.t(), Relay.Id.t(), :inet.ip_address() | nil) :: boolean()
  def touch(scope, api_client_id, ip) do
    work = fn _status -> ClientStore.touch(api_client_id, ip) end
    ClientStore.in_scope(scope, work) == {:ok, :touched}
  rescue
    _exception -> false
  end

  # API-44
  # API-77 (1)
  # API-77 (2)
  @doc "The API client traces of a scope with the warnings the operator sees: `over_cap` when the environment holds more than 50 clients and, per client, `unused` when it was not used for 90 days."
  @spec api_clients(Scope.t()) :: {:ok, map()} | {:error, term()}
  def api_clients(%Scope{} = scope) do
    now = Relay.Clock.utc_now()

    with {:ok, clients} <- ClientStore.in_scope(scope, fn _status -> ClientStore.list() end) do
      listed = Enum.map(clients, &Map.put(&1, :unused, unused?(&1, now)))
      {:ok, %{clients: listed, count: length(listed), over_cap: length(listed) > @client_cap}}
    end
  end

  defp unused?(%{status: "revoked"}, _now), do: false

  defp unused?(client, now) do
    since = client.last_used_at || client.created_at
    DateTime.diff(now, since, :second) >= @unused_days * 86_400
  end

  @doc "The client and unused warning thresholds of API-77 (1) and (2)."
  @spec client_limits() :: %{per_environment: pos_integer(), unused_days: pos_integer()}
  def client_limits, do: %{per_environment: @client_cap, unused_days: @unused_days}

  # E-36
  # E-70
  @doc "Receives an Access event delivery; see `Relay.Access.Events`. `request` carries `:webhook_id`, `:timestamp`, `:signature`, `:raw_body` and the decoded `:envelope`."
  @spec accept_event(map()) :: :ok | {:error, Relay.Error.t()}
  defdelegate accept_event(request), to: Events, as: :accept

  # E-36
  @doc "Applies one Access event receipt; the `Relay.Access.EventConsumer` job calls it."
  @spec process_event(Relay.Id.t()) :: :ok | {:error, term()}
  defdelegate process_event(receipt_id), to: Events, as: :process

  # E-36
  # TN-20
  @doc "Queues again the deferred Access event receipts of an Access tenant, or those deferred for `reason` (such as `no_handler` once a user event handler exists)."
  @spec requeue_deferred(String.t() | nil, String.t() | nil) :: :ok
  defdelegate requeue_deferred(access_tenant_id, reason), to: Events, as: :requeue

  # E-24
  # API-45
  # API-79 (2)
  # TN-25
  @doc "Exchanges an Access access token for a subscriber token; see `Relay.Access.SubscriberToken.exchange/2`."
  @spec exchange_subscriber_token(map(), SubscriberToken.audiences()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate exchange_subscriber_token(params, audiences), to: SubscriberToken, as: :exchange

  # E-25
  # IN-41
  @doc "Verifies a subscriber token; see `Relay.Access.SubscriberToken.verify/2`."
  @spec verify_subscriber_token(String.t(), SubscriberToken.audiences()) ::
          {:ok, SubscriberToken.verified()} | {:error, Relay.Error.t()}
  defdelegate verify_subscriber_token(token, audiences), to: SubscriberToken, as: :verify

  # E-10
  # E-11
  # TN-9
  @doc "The message class of a platform tenant's event; see `Relay.Access.PlatformTenant.message_class/2`."
  @spec message_class(String.t() | nil, atom() | nil) :: atom() | nil
  defdelegate message_class(platform_product, declared), to: PlatformTenant

  # E-11
  # API-28
  @doc "The `dedup_key` of an event from its CloudEvents `source` and `id`."
  @spec dedup_key(String.t(), String.t()) :: String.t()
  defdelegate dedup_key(source, id), to: PlatformTenant

  # C-18
  # E-9
  # TN-9
  @doc "Creates the platform tenant of a Suiss product (`:product`, one of `Relay.Access.PlatformTenant.products/0`) from the Access tenant attributes, with its keys; it is isolated like every tenant."
  @spec create_platform_tenant(map(), Relay.Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Relay.Error.t()}
  def create_platform_tenant(%{product: product} = attrs, actor) do
    if product in PlatformTenant.products() do
      attrs
      |> Map.delete(:product)
      |> Map.put(:platform_product, product)
      |> Relay.Tenancy.Provisioning.create_tenant(actor)
    else
      {:error, Relay.Error.new(:invalid_argument, "not a Suiss product")}
    end
  end

  # API-25
  @doc """
  Selects the sub-tenant of a request (API-25): the API client's own binding cannot be overridden. `requested` is the request's `tenant` (`stn_…`) or `nil`. A client bound to a sub-tenant gets it; a request naming another one, an unknown one or an archived one is `{:skipped, :scope_mismatch}`, recorded and visible, never an error that hides the request.
  """
  @spec select_subtenant(Scope.t(), Relay.Id.t() | nil, String.t() | nil) ::
          {:ok, Relay.Id.t() | nil} | {:skipped, :scope_mismatch} | {:error, term()}
  def select_subtenant(_scope, bound, nil), do: {:ok, bound}

  def select_subtenant(scope, bound, requested) when is_binary(requested) do
    case Relay.ExternalId.decode(requested, ["stn"]) do
      {:ok, ^bound} -> {:ok, bound}
      {:ok, id} when is_nil(bound) -> existing_subtenant(scope, id)
      _other -> {:skipped, :scope_mismatch}
    end
  end

  defp existing_subtenant(scope, id) do
    case ClientStore.in_scope(scope, fn _status -> ClientStore.subtenant_state(id) end) do
      {:ok, "active"} -> {:ok, id}
      {:ok, _missing_or_archived} -> {:skipped, :scope_mismatch}
      {:error, error} -> {:error, error}
    end
  end

  defp invalid(message), do: {:error, Relay.Error.new(:auth_invalid_token, message)}

  defp now, do: DateTime.to_unix(Relay.Clock.utc_now())
end
