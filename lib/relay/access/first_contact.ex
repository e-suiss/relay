defmodule Relay.Access.FirstContact do
  @moduledoc """
  The issuer of first-contact tokens as Relay knows it (AG-73, Access E58): Access issues the Privacy Pass tokens and publishes its token keys in an issuer directory (RFC 9578 §4) at `<issuer>/v1/first-contact/keys`, under the linked issuer. Relay reads that directory through the link's HTTP client, never inside a transaction, keeps the keys for ten minutes and verifies tokens with them without calling Access.

  The directory is a JSON object whose `token-keys` lists the keys that still verify, each with `token-type` 2 and `token-key`, the key in unpadded base64url. A key that is not of type 2 is left out. A directory that cannot be read, or that lists no key, leaves no key: it is remembered as empty for thirty seconds, so until Access publishes a key every first contact that needs a token is refused. `refresh/0` reads the directory again, at most once every thirty seconds on a node, for a token signed by a key the kept directory does not list.

  The challenge a token answers names the issuer by the host of the linked issuer and Relay, the origin, by the host of its own address (`config :relay, Relay.Access, event_receiver: "https://<host>/…"`).
  """

  alias Relay.Access.Cache
  alias Relay.Access.Http

  @path "/v1/first-contact/keys"
  @keys_ms 600_000
  @empty_ms 30_000
  @again_ms 30_000
  @token_type 2
  @max_keys 8

  @typedoc "The issuer's name, the origin's name and the issuer's token keys as published."
  @type issuer :: %{issuer_name: String.t(), origin: String.t(), token_keys: [binary()]}

  # AG-73
  @doc "The issuer with the token keys kept on this node, read from the directory when none are kept; `:unconfigured` without a linked issuer or an address of Relay's own."
  @spec issuer() :: {:ok, issuer()} | :unconfigured
  def issuer do
    with {:ok, names} <- names() do
      case Cache.fetch(:first_contact_keys) do
        {:ok, keys} -> {:ok, Map.put(names, :token_keys, keys)}
        :miss -> {:ok, Map.put(names, :token_keys, read())}
      end
    end
  end

  # AG-73
  @doc "The issuer with the token keys read from the directory now, when this node may ask again; otherwise as `issuer/0`."
  @spec refresh() :: {:ok, issuer()} | :unconfigured
  def refresh do
    with {:ok, names} <- names() do
      if Cache.claim(:first_contact_keys, @again_ms),
        do: {:ok, Map.put(names, :token_keys, read())},
        else: issuer()
    end
  end

  # AG-73
  @doc "Forgets the kept token keys, so that the next token reads the directory."
  @spec forget() :: :ok
  def forget do
    :ok = Cache.delete(:first_contact_keys)
    Cache.delete({:claim, :first_contact_keys})
  end

  defp names do
    with issuer when is_binary(issuer) <- Relay.Access.issuer(),
         %URI{host: issuer_name} when is_binary(issuer_name) <- URI.parse(issuer),
         receiver when is_binary(receiver) <-
           Keyword.get(Relay.Access.config(), :event_receiver),
         %URI{host: origin} when is_binary(origin) <- URI.parse(receiver) do
      {:ok, %{issuer_name: issuer_name, origin: origin}}
    else
      _unset -> :unconfigured
    end
  end

  # INV-55
  defp read do
    keys =
      case Http.get_json(String.trim_trailing(Relay.Access.issuer(), "/") <> @path) do
        {:ok, %{"token-keys" => listed}, _raw} when is_list(listed) -> token_keys(listed)
        _unreadable -> []
      end

    :ok = Cache.put(:first_contact_keys, keys, if(keys == [], do: @empty_ms, else: @keys_ms))
    keys
  end

  defp token_keys(listed) do
    keys =
      for %{"token-type" => @token_type, "token-key" => text} <- listed,
          is_binary(text),
          {:ok, key} <- [Base.url_decode64(text, padding: false)],
          do: key

    Enum.take(keys, @max_keys)
  end
end
