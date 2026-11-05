defmodule Relay.Channels.Push.WebPush.Vapid do
  @moduledoc """
  Voluntary application server identification (RFC 8292) for Web Push. Every channel identity (web application) has its own VAPID key pair in the key store; no key is shared by a tenant or an installation (C-26, TN-31). The token is an ES256 JWT signed in the key store, its `exp` is at most 24 hours ahead, and it is cached per key and push service and renewed an hour before it expires.

  A key rotation keeps the old key: an identity lists its keys newest first, new subscriptions get the newest key, and a subscription keeps being served by the key it was created with until that key is retired by an explicit operator action, which invalidates its subscriptions (CH-26, TN-31).
  """

  alias Relay.Channels.Push.Jwt
  alias Relay.Error

  @lifetime 23 * 3600
  @max_lifetime 24 * 3600
  @renew_before 3600

  @typedoc "A VAPID key: its key store label and its uncompressed P-256 public key."
  @type key :: %{label: Relay.Keys.label(), public_key: <<_::520>>}

  @typedoc "A channel identity: the contact `subject` (`mailto:` or `https:`) and its keys, newest first."
  @type identity :: %{subject: String.t(), keys: [key(), ...]}

  @typedoc "Cached tokens by key label and push service origin."
  @type cache :: %{optional({Relay.Keys.label(), String.t()}) => entry()}

  @typedoc "A cached token and its `exp`."
  @type entry :: %{token: String.t(), exp: integer()}

  # TN-31
  @doc "The token lifetime in seconds; `exp` is `now` plus this value."
  @spec lifetime() :: pos_integer()
  def lifetime, do: @lifetime

  # TN-31
  @doc "Reads the public half of the key store key `label` into a VAPID key."
  @spec key(Relay.Keys.label(), (Relay.Keys.alg(), Relay.Keys.label() -> term())) ::
          {:ok, key()} | {:error, Error.t()}
  def key(label, public_key \\ &Relay.Keys.public_key/2) when is_binary(label) do
    case public_key.(:es256, label) do
      {:ok, <<4, _::512>> = point} -> {:ok, %{label: label, public_key: point}}
      {:ok, _other} -> {:error, Error.new(:vapid_key_invalid, "the VAPID key is not P-256")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # C-26
  # TN-31
  @doc "Builds an identity from its contact subject and keys, newest first."
  @spec identity(String.t(), [key(), ...]) :: {:ok, identity()} | {:error, Error.t()}
  def identity(subject, [_ | _] = keys) when is_binary(subject) do
    cond do
      not subject?(subject) ->
        {:error, Error.new(:vapid_subject_invalid, "the VAPID subject is not mailto: or https:")}

      length(Enum.uniq_by(keys, & &1.label)) != length(keys) ->
        {:error, Error.new(:vapid_key_duplicate, "a VAPID key is listed twice")}

      true ->
        {:ok, %{subject: subject, keys: keys}}
    end
  end

  # CH-26
  # TN-31
  @doc "Adds a new key as the newest; existing subscriptions stay on their keys."
  @spec rotate(identity(), key()) :: {:ok, identity()} | {:error, Error.t()}
  def rotate(%{keys: keys} = identity, %{label: _, public_key: <<4, _::512>>} = key),
    do: identity(identity.subject, [key | keys])

  # CH-26
  # TN-31
  @doc "Retires a key by an explicit operator action; the subscriptions made with it become invalid. The last key cannot be retired."
  @spec retire(identity(), Relay.Keys.label()) :: {:ok, identity()} | {:error, Error.t()}
  def retire(%{keys: keys} = identity, label) when is_binary(label) do
    case Enum.reject(keys, &(&1.label == label)) do
      ^keys -> {:error, Error.new(:vapid_key_unknown, "the identity has no such key")}
      [] -> {:error, Error.new(:vapid_key_last, "the last VAPID key cannot be retired")}
      rest -> {:ok, %{identity | keys: rest}}
    end
  end

  # TN-31
  @doc "The key for a subscription: the one whose public key the subscription was created with, the newest key for a new subscription (`nil`)."
  @spec select_key(identity(), binary() | nil) :: {:ok, key()} | {:error, Error.t()}
  def select_key(%{keys: [newest | _]}, nil), do: {:ok, newest}

  def select_key(%{keys: keys}, subscription_key) when is_binary(subscription_key) do
    case Enum.find(keys, &(&1.public_key == subscription_key)) do
      nil -> {:error, Error.new(:vapid_key_retired, "the subscription's VAPID key is retired")}
      key -> {:ok, key}
    end
  end

  # CH-26
  @doc "The `aud` of a push endpoint: its HTTPS origin."
  @spec audience(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def audience(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, port: port} when is_binary(host) and host != "" ->
        {:ok, "https://" <> String.downcase(host) <> port(port)}

      _other ->
        {:error, Error.new(:web_push_endpoint_invalid, "the push endpoint is not an HTTPS URL")}
    end
  end

  defp port(443), do: ""
  defp port(nil), do: ""
  defp port(port), do: ":" <> Integer.to_string(port)

  # CH-26
  # TN-31
  @doc """
  Returns the `Authorization` header value (`vapid t=<jwt>, k=<public key>`) for a push to `endpoint` with `key`, at Unix time `now` in seconds, and the updated cache. A cached token is reused until an hour before its `exp`; a new one is signed in the key store through `signer`.
  """
  @spec authorization(identity(), key(), String.t(), integer(), cache(), Jwt.signer()) ::
          {:ok, String.t(), cache()} | {:error, Error.t()}
  def authorization(identity, key, endpoint, now, cache, signer \\ &Relay.Keys.sign/3)
      when is_integer(now) and is_map(cache) do
    with {:ok, aud} <- audience(endpoint),
         {:ok, token, cache} <- token(identity, key, aud, now, cache, signer) do
      {:ok, "vapid t=" <> token <> ", k=" <> Jwt.encode64(key.public_key), cache}
    end
  end

  defp token(identity, key, aud, now, cache, signer) do
    case Map.get(cache, {key.label, aud}) do
      %{token: token, exp: exp} when exp - now > @renew_before ->
        {:ok, token, cache}

      _missing_or_due ->
        sign(identity, key, aud, now, prune(cache, now), signer)
    end
  end

  defp sign(identity, key, aud, now, cache, signer) do
    exp = now + @lifetime
    claims = [{"aud", aud}, {"exp", exp}, {"sub", identity.subject}]

    with {:ok, token} <- Jwt.sign(:es256, key.label, [{"typ", "JWT"}], claims, signer),
         do: {:ok, token, Map.put(cache, {key.label, aud}, %{token: token, exp: exp})}
  end

  defp prune(cache, now), do: Map.reject(cache, fn {_key, entry} -> entry.exp <= now end)

  # CH-26
  @doc "Checks a token's claims as a push service does: `aud` is the endpoint origin and `exp` is in the future and at most 24 hours after `now`."
  @spec valid_claims?(map(), String.t(), integer()) :: boolean()
  def valid_claims?(%{"aud" => aud, "exp" => exp, "sub" => sub}, endpoint, now)
      when is_integer(exp) and is_binary(sub) do
    within = exp > now and exp - now <= @max_lifetime
    within and audience(endpoint) == {:ok, aud} and subject?(sub)
  end

  def valid_claims?(_claims, _endpoint, _now), do: false

  defp subject?("mailto:" <> rest), do: rest != ""
  defp subject?("https://" <> rest), do: rest != ""
  defp subject?(_subject), do: false
end
