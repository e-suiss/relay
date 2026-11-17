defmodule Relay.Access.FirstContact do
  @moduledoc """
  The issuers of first-contact tokens as Relay knows them (AG-73, E-103, Access E58): every Access environment of a tenant issues its own Privacy Pass tokens and publishes its token keys in its own issuer directory (RFC 9578 §4) at `<issuer>/v1/first-contact/keys`, under the Access environment's issuer from the tenant snapshot (`Relay.Access.Environments`): the host root of a subdomain environment or `<base>/env/{slug}`. Relay reads each directory through the link's HTTP client, never inside a transaction, keeps its keys for ten minutes per issuer and verifies tokens with them without calling Access.

  A directory is a JSON object whose `token-keys` lists the keys that still verify, each with `token-type` 2, `token-key`, the key in unpadded base64url, and `not-before`, the Unix second from which the key is used. A key is usable only from its `not-before` on, by the node's clock; a key without `not-before` is usable at once, and a key that is not of type 2 or whose `not-before` is not a non-negative integer is left out. A directory that cannot be read, or that lists no key, leaves no key: it is remembered as empty for thirty seconds, so until Access publishes a key every first contact that needs a token is refused. A tenant without a known Access environment has no issuer at all. `refresh/1` reads the directories again, at most once every thirty seconds per issuer on a node, for a token signed by a key the kept directories do not list.

  The challenge a token answers names the issuer by the host of its Access environment's issuer and Relay, the origin, by the host of its own address (`config :relay, Relay.Access, event_receiver: "https://<host>/…"`).
  """

  alias Relay.Access.Cache
  alias Relay.Access.Environments
  alias Relay.Access.Http

  @path "/v1/first-contact/keys"
  @keys_ms 600_000
  @empty_ms 30_000
  @again_ms 30_000
  @token_type 2
  @max_keys 8

  @typedoc "One issuer: its name, the origin's name and its token keys usable now."
  @type issuer :: %{issuer_name: String.t(), origin: String.t(), token_keys: [binary()]}

  # AG-73
  # E-103
  @doc "The issuers of the Access environments of the scope's tenant with the token keys kept on this node, each directory read when none are kept; `:unconfigured` without a linked issuer or an address of Relay's own."
  @spec issuers(Relay.Scope.t()) :: {:ok, [issuer()]} | :unconfigured
  def issuers(scope), do: with_issuers(scope, &kept/1)

  # AG-73
  # E-103
  @doc "The issuers as `issuers/1`, each directory read again now when this node may ask its issuer again."
  @spec refresh(Relay.Scope.t()) :: {:ok, [issuer()]} | :unconfigured
  def refresh(scope), do: with_issuers(scope, &again/1)

  # AG-73
  @doc "Forgets every kept token key, so that the next token reads the directories."
  @spec forget() :: :ok
  def forget do
    :ok = Cache.forget({:first_contact_keys, :_})
    Cache.forget({:claim, {:first_contact_keys, :_}})
  end

  # AG-73
  # E-103
  @doc "The token keys of a directory's `token-keys` that are usable at Unix second `now_s`: of type 2 and, when they name one, at or after their `not-before`."
  @spec usable([term()], integer()) :: [binary()]
  def usable(listed, now_s) when is_list(listed), do: due(entries(listed), now_s)

  defp due(entries, now_s) do
    keys = for {key, not_before} <- entries, not_before <= now_s, do: key
    Enum.take(keys, @max_keys)
  end

  defp with_issuers(scope, read) do
    with {:ok, origin} <- origin() do
      now_s = DateTime.to_unix(Relay.Clock.utc_now())

      issuers =
        for issuer <- environment_issuers(scope),
            %URI{host: name} when is_binary(name) <- [URI.parse(issuer)],
            do: %{issuer_name: name, origin: origin, token_keys: due(read.(issuer), now_s)}

      {:ok, issuers}
    end
  end

  defp origin do
    with issuer when is_binary(issuer) <- Relay.Access.issuer(),
         receiver when is_binary(receiver) <-
           Keyword.get(Relay.Access.config(), :event_receiver),
         %URI{host: origin} when is_binary(origin) <- URI.parse(receiver) do
      {:ok, origin}
    else
      _unset -> :unconfigured
    end
  end

  defp environment_issuers(scope) do
    with {:ok, %{"access_tenant_id" => tenant}} when is_binary(tenant) <-
           Relay.Tenancy.tenant(scope),
         {:ok, issuers} when is_list(issuers) <- Environments.issuers(tenant) do
      issuers
    else
      _none -> []
    end
  end

  defp kept(issuer) do
    case Cache.fetch({:first_contact_keys, issuer}) do
      {:ok, entries} -> entries
      :miss -> read(issuer)
    end
  end

  defp again(issuer) do
    if Cache.claim({:first_contact_keys, issuer}, @again_ms),
      do: read(issuer),
      else: kept(issuer)
  end

  # INV-55
  defp read(issuer) do
    entries =
      case Http.get_json(String.trim_trailing(issuer, "/") <> @path) do
        {:ok, %{"token-keys" => listed}, _raw} when is_list(listed) -> entries(listed)
        _unreadable -> []
      end

    ttl = if entries == [], do: @empty_ms, else: @keys_ms
    :ok = Cache.put({:first_contact_keys, issuer}, entries, ttl)
    entries
  end

  defp entries(listed) do
    for %{"token-type" => @token_type, "token-key" => text} = entry <- listed,
        is_binary(text),
        {:ok, key} <- [Base.url_decode64(text, padding: false)],
        {:ok, not_before} <- [not_before(entry)],
        do: {key, not_before}
  end

  defp not_before(%{"not-before" => seconds}) when is_integer(seconds) and seconds >= 0,
    do: {:ok, seconds}

  defp not_before(%{"not-before" => _invalid}), do: :error
  defp not_before(_entry), do: {:ok, 0}
end
