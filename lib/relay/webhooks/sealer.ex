defmodule Relay.Webhooks.Sealer do
  @moduledoc """
  The port through which the webhook engine keeps a value encrypted under the tenant's data key (TN-27, TN-32): the key store label of a signing key, an HMAC secret, an operations contact address. The engine never sees the data key; it names the table and column the value is stored in, and a sealed value opens only for that column and scope. Both callbacks reach the key store, so neither runs inside a transaction. `Relay.Webhooks.Live` is the implementation of a running node.
  """

  @typedoc "The table and column a sealed value is stored in."
  @type field :: {table :: String.t(), column :: String.t()}

  @typedoc "A sealed value and the tenant key it was sealed under."
  @type sealed :: %{ct: binary(), key_id: Relay.Id.t()}

  @doc "Seals `plaintext` for `field` under the scope's active data key."
  @callback seal(Relay.Scope.t(), field(), binary() | Relay.Redacted.t()) ::
              {:ok, sealed()} | {:error, Relay.Error.t()}

  @doc "Opens a value sealed by `c:seal/3` for the same `field` under the key `key_id`; the plaintext comes back redacted."
  @callback open(Relay.Scope.t(), field(), Relay.Id.t(), binary()) ::
              {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
end
