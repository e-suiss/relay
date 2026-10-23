defmodule Relay.Tenancy.BlindIndex do
  @moduledoc """
  Keyed blind indexes for equality search over addresses and tokens: HMAC-SHA256, computed inside the key store under the tenant's blind index key, over the canonical encoding of tenant, environment, purpose and the normalized value. The output is not truncated. While a key is rotated in the index has one column per readable key; writes fill every column and reads match any of them.
  """

  alias Relay.Tenancy.KeyProvider

  @type digest :: <<_::256>>
  @type entry :: {KeyProvider.version(), digest()}

  # TN-33
  # TN-65 (2)
  # TN-66 (1)
  # OP-1
  @doc "Computes the index under every readable key, the current key first."
  @spec digests(module(), KeyProvider.index_scope(), binary() | Relay.Redacted.t()) ::
          {:ok, [entry(), ...]} | {:error, Relay.Error.t()}
  def digests(provider, scope, value) do
    with {:ok, message} <- message(scope, value),
         {:ok, [_ | _] = entries} <-
           provider.blind_index_macs(scope, Relay.Redacted.wrap(message)) do
      {:ok, entries}
    else
      {:ok, []} -> {:error, Relay.Error.new(:blind_index_key_unavailable, "no blind index key")}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Computes the index under the current key."
  @spec current(module(), KeyProvider.index_scope(), binary() | Relay.Redacted.t()) ::
          {:ok, entry()} | {:error, Relay.Error.t()}
  def current(provider, scope, value) do
    with {:ok, [entry | _]} <- digests(provider, scope, value), do: {:ok, entry}
  end

  # TN-35
  @doc "Returns true if a stored index entry equals one of the computed entries, compared in constant time."
  @spec matches?([entry()], entry()) :: boolean()
  def matches?(computed, {version, stored}) when is_binary(stored) do
    Enum.any?(computed, fn {computed_version, digest} ->
      computed_version == version and Relay.Crypto.secure_compare(digest, stored)
    end)
  end

  defp message(
         %{tenant_id: <<_::128>> = tenant_id, environment: environment, purpose: purpose},
         value
       )
       when is_binary(purpose) and purpose != "" do
    value = if Relay.Redacted.redacted?(value), do: Relay.Redacted.expose(value), else: value

    with {:ok, environment} <- Relay.Environment.cast(environment),
         true <- is_binary(value) do
      Relay.Canonical.encode([
        {:bytes, tenant_id},
        Relay.Environment.dump(environment),
        purpose,
        {:bytes, value}
      ])
    else
      _ -> invalid_scope()
    end
  end

  defp message(_scope, _value), do: invalid_scope()

  defp invalid_scope, do: {:error, Relay.Error.new(:invalid_scope, "invalid blind index scope")}
end
