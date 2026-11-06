defmodule Relay.Access.ServiceKey do
  @moduledoc """
  Relay's Access service key (E-101): the Ed25519 key of Relay's service Instance in every realm it pairs with, named by `config :relay, Relay.Access, service_key: label` (`access-service` by default) and kept in the key store (TN-63). Its public JWK is registered with Relay's client in Access next to the client key; Access names it in every pairing challenge by its RFC 7638 thumbprint (`kid`). `print_service_key/0` prints both (`bin/relay eval 'Relay.Access.ServiceKey.print_service_key()'`, or `mix relay.access.service_key` in development).
  """

  alias Relay.Access.Cache
  alias Relay.Access.Jose

  @jwk_ms 600_000

  @doc "The key-store label of the service key."
  @spec label() :: String.t()
  def label, do: Keyword.get(Relay.Access.config(), :service_key, "access-service")

  # E-101
  @doc "The 32-byte public key of the service key, read from the key store."
  @spec public_key() :: {:ok, <<_::256>>} | {:error, Relay.Error.t()}
  def public_key do
    label = label()

    case Cache.fetch({:service_key, label}) do
      {:ok, key} -> {:ok, key}
      :miss -> read(label)
    end
  end

  defp read(label) do
    case Relay.Keys.public_key(:ed25519, label) do
      {:ok, <<_::256>> = key} ->
        :ok = Cache.put({:service_key, label}, key, @jwk_ms)
        {:ok, key}

      _failed ->
        {:error,
         Relay.Error.new(:access_unreachable, "Access link: Relay's service key cannot be read")}
    end
  end

  # E-101
  @doc "The public JWK of a 32-byte Ed25519 key, with only its required members."
  @spec jwk(<<_::256>>) :: map()
  def jwk(<<_::256>> = key), do: %{"kty" => "OKP", "crv" => "Ed25519", "x" => Jose.encode(key)}

  # E-101
  @doc "The RFC 7638 thumbprint of a 32-byte Ed25519 key: SHA-256 of its JWK's required members in lexicographic order."
  @spec thumbprint(<<_::256>>) :: <<_::256>>
  def thumbprint(<<_::256>> = key),
    do: :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{Jose.encode(key)}"}))

  # E-101
  @doc "Prints the public JWK of the service key, with its RFC 7638 thumbprint as `kid`, to register it with Relay's client in Access; it starts the key store port when the node does not run it."
  @spec print_service_key() :: :ok
  def print_service_key do
    {:ok, _apps} = Application.ensure_all_started(:crypto)

    _started =
      Supervisor.start_link(Relay.Keys.children(),
        strategy: :one_for_one,
        max_restarts: 0,
        max_seconds: 1
      )

    case Relay.Keys.public_key(:ed25519, label()) do
      {:ok, <<_::256>> = key} ->
        kid = Jose.encode(thumbprint(key))
        IO.puts(Jason.encode!(Map.merge(jwk(key), %{"kid" => kid, "use" => "sig"})))

      {:ok, _other} ->
        raise "the service key is not an Ed25519 key"

      {:error, error} ->
        raise error.message
    end
  end
end
