defmodule Relay.Tenancy.FieldCipher do
  @moduledoc """
  Field encryption for personal data: AES-256-GCM under the data key of the subject and retention class (or under a tenant data key for a field without a subject), with a fresh 96-bit nonce from `Relay.Random` per encryption. The associated data is the canonical encoding of the format byte, tenant, environment, subject, retention class, table and column, so a ciphertext only decrypts in the column and scope it was written for. The stored form is `format || nonce || ciphertext || tag`. Destroying the data key shreds every field it protects.
  """

  alias Relay.Tenancy.KeyProvider

  @format 1
  @nonce_bytes 12
  @tag_bytes 16
  @typedoc "A key provider module, or `{:key, data_key}` for a key the caller already holds."
  @type provider :: module() | {:key, Relay.Redacted.t()}

  @table ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @column ~r/\A[a-z][a-z0-9_]{0,59}_ct\z/

  # TN-33
  # TN-35
  # TN-65 (4)
  # TN-66 (3)
  # OP-17
  # OP-18
  @doc "Encrypts a field value under the data key of `scope`."
  @spec encrypt(provider(), KeyProvider.data_key_scope(), binary() | Relay.Redacted.t()) ::
          {:ok, binary()} | {:error, Relay.Error.t()}
  def encrypt(provider, scope, plaintext) do
    plaintext =
      if Relay.Redacted.redacted?(plaintext),
        do: Relay.Redacted.expose(plaintext),
        else: plaintext

    with true <- is_binary(plaintext) || invalid_plaintext(),
         {:ok, aad} <- aad(scope),
         {:ok, key} <- data_key(provider, scope) do
      nonce = Relay.Random.bytes(@nonce_bytes)
      {ciphertext, tag} = Relay.Crypto.aes_256_gcm_encrypt(key, nonce, plaintext, aad)
      {:ok, <<@format, nonce::binary, ciphertext::binary, tag::binary>>}
    end
  end

  @doc "Decrypts a stored field value written for `scope`; the plaintext is returned redacted."
  @spec decrypt(provider(), KeyProvider.data_key_scope(), binary()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def decrypt(provider, scope, stored) do
    with {:ok, nonce, ciphertext, tag} <- split(stored),
         {:ok, aad} <- aad(scope),
         {:ok, key} <- data_key(provider, scope) do
      case Relay.Crypto.aes_256_gcm_decrypt(key, nonce, ciphertext, aad, tag) do
        {:ok, plaintext} -> {:ok, Relay.Redacted.wrap(plaintext)}
        :error -> {:error, Relay.Error.new(:decryption_failed, "field does not authenticate")}
      end
    end
  end

  defp split(<<@format, nonce::binary-size(@nonce_bytes), rest::binary>>)
       when byte_size(rest) >= @tag_bytes do
    size = byte_size(rest) - @tag_bytes
    <<ciphertext::binary-size(^size), tag::binary-size(@tag_bytes)>> = rest
    {:ok, nonce, ciphertext, tag}
  end

  defp split(_stored),
    do: {:error, Relay.Error.new(:invalid_ciphertext, "not an encrypted field")}

  defp data_key(provider, scope) do
    with {:ok, key} <- fetch_key(provider, scope) do
      case Relay.Redacted.expose(key) do
        <<_::256>> -> {:ok, key}
        _ -> {:error, Relay.Error.new(:invalid_data_key, "data key is not 32 bytes")}
      end
    end
  end

  defp fetch_key({:key, key}, _scope), do: {:ok, key}
  defp fetch_key(provider, scope) when is_atom(provider), do: provider.data_key(scope)

  defp aad(
         %{
           tenant_id: <<_::128>> = tenant_id,
           environment: environment,
           subject_id: subject_id,
           retention_class: class,
           table: table,
           column: column
         } = scope
       )
       when is_binary(table) and is_binary(column) do
    with true <- subject?(subject_id, scope),
         true <- Regex.match?(@table, table) and Regex.match?(@column, column),
         {:ok, environment} <- Relay.Environment.cast(environment),
         {:ok, class} <- Relay.RetentionClass.cast(class) do
      Relay.Canonical.encode([
        @format,
        {:bytes, tenant_id},
        Relay.Environment.dump(environment),
        if(subject_id, do: {:bytes, subject_id}),
        Relay.RetentionClass.dump(class),
        table,
        column
      ])
    else
      _ -> invalid_scope()
    end
  end

  defp aad(_scope), do: invalid_scope()

  defp subject?(<<_::128>>, _scope), do: true
  defp subject?(nil, %{key_id: <<_::128>>}), do: true
  defp subject?(_subject_id, _scope), do: false

  defp invalid_scope, do: {:error, Relay.Error.new(:invalid_scope, "invalid data key scope")}

  defp invalid_plaintext,
    do: {:error, Relay.Error.new(:invalid_plaintext, "field value is not a binary")}
end
