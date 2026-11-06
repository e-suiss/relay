defmodule Relay.Access.Realms do
  @moduledoc """
  The realms of the Access tenants (E-96). A token of a tenant API client or of an end user is issued by the caller's realm: its `iss` is one of the realm issuers of the token's `access_tenant`, not the linked issuer. Relay reads those issuers from the tenant snapshot (`GET /access/v1/tenants/{tenant}/snapshot`, Access OP-149 item 4, at the `endpoints.tenant_snapshot` address of the linked issuer's Suiss configuration) through `Relay.Access.Client.product_get/2`, and each realm's keys from its own discovery: `<realm issuer>/.well-known/openid-configuration`, whose `issuer` must be the realm issuer and whose `jwks_uri` names the key set.

  Issuers are kept for five minutes and keys for ten in `Relay.Access.Cache`. An issuer the cached snapshot does not name reads the snapshot again, and a `kid` the cached keys do not hold reads the keys again, each at most once every 30 seconds per tenant or realm. A tenant Access does not know is remembered as unknown for five minutes.

  The token's `iss` and `access_tenant` are read unverified only to choose the keys; nothing in the token is trusted before its signature verifies under them. A tenant Access does not know, an issuer that is not one of the tenant's realms and a key the realm does not publish are `auth_invalid_token`; an Access that cannot answer is `service_unavailable`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Discovery
  alias Relay.Access.Http
  alias Relay.Access.Jose
  alias Relay.Access.Token

  @realms_ms 300_000
  @keys_ms 600_000
  @template_ms 300_000
  @again_ms 30_000
  @tenant ~r/\A[A-Za-z0-9_-]{1,128}\z/

  # E-96
  # E-93
  @doc "Verifies a token issued by a realm of its `access_tenant`: `claimed` are its unverified claims, `expectation` the checks of `Relay.Access.Token.verify/3` without the issuer, which becomes the token's realm issuer once the tenant's snapshot names it."
  @spec verify(String.t(), map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def verify(token, claimed, expectation) do
    with {:ok, tenant} <- tenant(claimed["access_tenant"]),
         {:ok, issuer} <- member(tenant, claimed["iss"]),
         do: signed(token, issuer, Map.put(expectation, :issuer, issuer))
  end

  # E-95
  # E-96
  @doc "Reads the snapshot of an Access tenant from Access now (Access OP-149 item 4): `{:error, :not_found}` when Access does not know the tenant."
  @spec snapshot(String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, Relay.Error.t()}
  def snapshot(access_tenant) do
    with {:ok, tenant} <- tenant(access_tenant),
         {:ok, template} <- template(),
         do: Client.product_get(String.replace(template, "{tenant}", encode(tenant)))
  end

  # E-96
  @doc "The realm issuers of an Access tenant, from the cache or from its snapshot; `:unknown` when Access does not know the tenant."
  @spec issuers(String.t()) :: {:ok, [String.t()] | :unknown} | {:error, Relay.Error.t()}
  def issuers(access_tenant) do
    case Cache.fetch({:realms, access_tenant}) do
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
    with true <- Cache.claim({:realms, tenant}, @again_ms),
         {:ok, issuers} <- read_issuers(tenant),
         true <- listed?(issuers, issuer) do
      {:ok, issuer}
    else
      {:error, error} -> {:error, error}
      false -> invalid("the token is not issued by a realm of its Access tenant")
    end
  end

  defp listed?(issuers, issuer) when is_list(issuers),
    do: Enum.any?(issuers, &Token.same?(&1, issuer))

  defp listed?(:unknown, _issuer), do: false

  defp read_issuers(tenant) do
    case snapshot(tenant) do
      {:ok, snapshot} -> keep({:realms, tenant}, realm_issuers(tenant, snapshot), @realms_ms)
      {:error, :not_found} -> keep({:realms, tenant}, :unknown, @realms_ms)
      {:error, error} -> unavailable(error)
    end
  end

  defp realm_issuers(tenant, %{"tenant" => tenant, "realms" => realms}) when is_list(realms) do
    for %{"issuer" => issuer} <- realms,
        is_binary(issuer),
        String.starts_with?(issuer, "https://"),
        do: issuer
  end

  defp realm_issuers(_tenant, _snapshot), do: []

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
    with true <- Cache.claim({:realm_keys, issuer}, @again_ms),
         {:ok, keys} <- read_keys(issuer),
         {:ok, claims} <- Token.verify(token, keys, expectation) do
      {:ok, claims}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _unknown -> invalid("the token is signed by a key its realm does not publish")
    end
  end

  defp keys(issuer) do
    case Cache.fetch({:realm_keys, issuer}) do
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
      keep({:realm_keys, issuer}, keys, @keys_ms)
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
    do: {:error, Relay.Error.new(:service_unavailable, "the Access realm cannot be read now")}

  defp invalid(message), do: {:error, Relay.Error.new(:auth_invalid_token, message)}
end
