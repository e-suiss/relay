defmodule Relay.Access.Environments do
  @moduledoc """
  The Access environments of the Access tenants (E-96, E-103). Access calls them environments; inside Relay they are Access environments (`access_environment`), apart from Relay's own `live` and `test` environments. A token of a tenant API client or of an end user is issued by the caller's Access environment: its `iss` is one of the Access environment issuers of the token's `access_tenant`, not the linked issuer. Relay reads those issuers from the tenant snapshot (`GET /access/v1/tenants/{tenant}/snapshot`, Access OP-149 item 4, at the `endpoints.tenant_snapshot` address of the linked issuer's Suiss configuration) through `Relay.Access.Client.product_get/2`, and each Access environment's keys from its own discovery: `<issuer>/.well-known/openid-configuration`, whose `issuer` must be the Access environment issuer and whose `jwks_uri` names the key set. An issuer is the host root of a subdomain environment or `<base>/env/{slug}` for a path environment.

  The snapshot lists the Access environments in `environments`, each `{id, issuer, slug}`. A snapshot of an Access release before the rename names the same list `realms`; it is read the same way while no `environments` member is present.

  Issuers are kept for five minutes and keys for ten in `Relay.Access.Cache`. An issuer the cached snapshot does not name reads the snapshot again, and a `kid` the cached keys do not hold reads the keys again, each at most once every 30 seconds per tenant or Access environment. A tenant Access does not know is remembered as unknown for five minutes.

  The token's `iss` and `access_tenant` are read unverified only to choose the keys; nothing in the token is trusted before its signature verifies under them. A tenant Access does not know, an issuer that is not one of the tenant's Access environments and a key the Access environment does not publish are `auth_invalid_token`; an Access that cannot answer is `service_unavailable`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Discovery
  alias Relay.Access.Http
  alias Relay.Access.Jose
  alias Relay.Access.Token

  @issuers_ms 300_000
  @keys_ms 600_000
  @template_ms 300_000
  @again_ms 30_000
  @tenant ~r/\A[A-Za-z0-9_-]{1,128}\z/

  # E-96
  # E-93
  # E-103
  @doc "Verifies a token issued by an Access environment of its `access_tenant`: `claimed` are its unverified claims, `expectation` the checks of `Relay.Access.Token.verify/3` without the issuer, which becomes the token's Access environment issuer once the tenant's snapshot names it."
  @spec verify(String.t(), map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def verify(token, claimed, expectation) do
    with {:ok, tenant} <- tenant(claimed["access_tenant"]),
         {:ok, issuer} <- member(tenant, claimed["iss"]),
         do: signed(token, issuer, Map.put(expectation, :issuer, issuer))
  end

  # E-95
  # E-96
  # E-103
  @doc "Reads the snapshot of an Access tenant from Access now (Access OP-149 item 4): `{:error, :not_found}` when Access does not know the tenant."
  @spec snapshot(String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, Relay.Error.t()}
  def snapshot(access_tenant) do
    with {:ok, tenant} <- tenant(access_tenant),
         {:ok, template} <- template(),
         do: Client.product_get(String.replace(template, "{tenant}", encode(tenant)))
  end

  # E-103
  @doc "The Access environments a snapshot of `access_tenant` lists, as Access writes them: its `environments`, or its `realms` when it has no `environments`; `:error` for a snapshot of another tenant or without a list."
  @spec listed(map(), String.t()) :: {:ok, [term()]} | :error
  def listed(%{"tenant" => tenant} = snapshot, tenant) do
    case Map.get(snapshot, "environments", snapshot["realms"]) do
      list when is_list(list) -> {:ok, list}
      _missing -> :error
    end
  end

  def listed(_snapshot, _tenant), do: :error

  # E-96
  # E-103
  @doc "The Access environment issuers of an Access tenant, from the cache or from its snapshot; `:unknown` when Access does not know the tenant."
  @spec issuers(String.t()) :: {:ok, [String.t()] | :unknown} | {:error, Relay.Error.t()}
  def issuers(access_tenant) do
    case Cache.fetch({:access_environment_issuers, access_tenant}) do
      {:ok, issuers} -> {:ok, issuers}
      :miss -> read_issuers(access_tenant)
    end
  end

  defp tenant(tenant) when is_binary(tenant) do
    if Regex.match?(@tenant, tenant),
      do: {:ok, tenant},
      else: invalid("the token names no valid Access tenant")
  end

  defp tenant(_tenant), do: invalid("the token names no Access tenant")

  defp member(tenant, issuer) when is_binary(issuer) do
    with {:ok, issuers} <- issuers(tenant) do
      if listed?(issuers, issuer), do: {:ok, issuer}, else: again(tenant, issuer)
    end
  end

  defp member(_tenant, _issuer), do: invalid("the token names no issuer")

  defp again(tenant, issuer) do
    with true <- Cache.claim({:access_environment_issuers, tenant}, @again_ms),
         {:ok, issuers} <- read_issuers(tenant),
         true <- listed?(issuers, issuer) do
      {:ok, issuer}
    else
      {:error, error} -> {:error, error}
      false -> invalid("the token is not issued by an Access environment of its Access tenant")
    end
  end

  defp listed?(issuers, issuer) when is_list(issuers),
    do: Enum.any?(issuers, &Token.same?(&1, issuer))

  defp listed?(:unknown, _issuer), do: false

  defp read_issuers(tenant) do
    key = {:access_environment_issuers, tenant}

    case snapshot(tenant) do
      {:ok, snapshot} -> keep(key, environment_issuers(tenant, snapshot), @issuers_ms)
      {:error, :not_found} -> keep(key, :unknown, @issuers_ms)
      {:error, error} -> unavailable(error)
    end
  end

  defp environment_issuers(tenant, snapshot) do
    case listed(snapshot, tenant) do
      {:ok, environments} ->
        for %{"issuer" => issuer} <- environments,
            is_binary(issuer),
            String.starts_with?(issuer, "https://"),
            do: issuer

      :error ->
        []
    end
  end

  defp template do
    case Cache.fetch(:tenant_snapshot) do
      {:ok, template} -> {:ok, template}
      :miss -> read_template()
    end
  end

  defp read_template do
    with {:ok, issuer} <- linked_issuer(),
         {:ok, document, _raw} <- Http.get_json(Discovery.suiss_url(issuer)),
         {:ok, %{tenant_snapshot: template}} when is_binary(template) <-
           Discovery.parse_suiss(document, issuer) do
      keep(:tenant_snapshot, template, @template_ms)
    else
      {:ok, _suiss} -> {:error, Relay.Error.new(:access_discovery_invalid, "no tenant snapshot")}
      {:error, error} -> {:error, error}
    end
  end

  defp linked_issuer do
    case Relay.Access.issuer() do
      issuer when is_binary(issuer) ->
        {:ok, issuer}

      _unset ->
        {:error, Relay.Error.new(:access_not_configured, "no Access issuer is configured")}
    end
  end

  defp signed(token, issuer, expectation) do
    with {:ok, keys} <- keys(issuer) do
      case Token.verify(token, keys, expectation) do
        {:error, :unknown_key} -> fresh_keys(token, issuer, expectation)
        result -> result
      end
    end
  end

  defp fresh_keys(token, issuer, expectation) do
    with true <- Cache.claim({:access_environment_keys, issuer}, @again_ms),
         {:ok, keys} <- read_keys(issuer),
         {:ok, claims} <- Token.verify(token, keys, expectation) do
      {:ok, claims}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _unknown -> invalid("the token is signed by a key its Access environment does not publish")
    end
  end

  defp keys(issuer) do
    case Cache.fetch({:access_environment_keys, issuer}) do
      {:ok, keys} -> {:ok, keys}
      :miss -> read_keys(issuer)
    end
  end

  # E-78
  # E-96
  defp read_keys(issuer) do
    with {:ok, document, _raw} <- Http.get_json(Discovery.openid_url(issuer)),
         {:ok, parsed} <- Discovery.parse(document, issuer),
         {:ok, jwks, _raw} <- Http.get_json(parsed.jwks_uri),
         {:ok, keys, _public} <- Jose.public_keys(jwks) do
      keep({:access_environment_keys, issuer}, keys, @keys_ms)
    else
      {:error, error} -> unavailable(error)
    end
  end

  defp keep(key, value, ttl_ms) do
    :ok = Cache.put(key, value, ttl_ms)
    {:ok, value}
  end

  defp encode(tenant), do: URI.encode(tenant, &URI.char_unreserved?/1)

  defp unavailable(%Relay.Error{code: :auth_invalid_token} = error), do: {:error, error}

  defp unavailable(_error),
    do: {:error, Relay.Error.new(:service_unavailable, "an Access environment is unreadable")}

  defp invalid(message), do: {:error, Relay.Error.new(:auth_invalid_token, message)}
end
