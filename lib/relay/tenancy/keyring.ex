defmodule Relay.Tenancy.Keyring do
  @moduledoc """
  Production key provider: envelope encryption over the PKCS#11 key store.

  A tenant key (`data`, `dek_wrap`) is 32 random bytes wrapped inside the key store under the region KEK with AES-256-GCM; the stored form is `version || iv || ciphertext || tag`, the IV drawn by the token. A subject data key is 32 random bytes wrapped under the tenant's `dek_wrap` key with AES-256-GCM in the same stored form. Unwrapped keys stay in `Relay.Tenancy.KeyCache` for ten minutes, so the key store is asked once per key and cache lifetime, never per message. A restricted data key (statutory retention) and a destroyed key are refused. Blind index HMACs are computed inside the key store; the HMAC key never leaves it.

  Keys are read in a transaction of their own and unwrapped after it commits, so none of these functions may run inside another transaction.
  """

  @behaviour Relay.Tenancy.KeyProvider

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Tenancy.KeyCache
  alias Relay.Tenancy.Store

  @version 1
  @key_bytes 32
  @iv_bytes 12
  @tag_bytes 16

  @type purpose :: :data | :dek_wrap

  # TN-33
  # TN-66 (1)
  @impl Relay.Tenancy.KeyProvider
  @doc "Computes the blind index HMACs of a message inside the key store; see `Relay.Tenancy.KeyProvider`."
  @spec blind_index_macs(Relay.Tenancy.KeyProvider.index_scope(), Redacted.t()) ::
          {:ok, [{Relay.Id.t(), <<_::256>>}]} | {:error, Error.t()}
  def blind_index_macs(%{tenant_id: tenant_id, environment: environment}, message) do
    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
         {:ok, keys} <- read(scope, &Store.blind_index_keys/0),
         do: macs(keys, message, [])
  end

  # TN-27
  # TN-66 (2)
  # OP-18
  @impl Relay.Tenancy.KeyProvider
  @doc "Returns the data key of a field scope; see `Relay.Tenancy.KeyProvider`."
  @spec data_key(Relay.Tenancy.KeyProvider.data_key_scope()) ::
          {:ok, Redacted.t()} | {:error, Error.t()}
  def data_key(%{tenant_id: tenant_id, environment: environment} = field) do
    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment), do: field_key(scope, field)
  end

  # TN-27
  # TN-65 (1)
  @doc "Generates a tenant key and wraps it under the region KEK `kek_label` inside the key store. Returns the KEK reference and the stored wrapped form to register."
  @spec generate_tenant_key(Relay.Scope.t(), Relay.Id.t(), purpose(), Relay.Keys.label()) ::
          {:ok, %{kek_ref: String.t(), wrapped_key: binary()}} | {:error, Error.t()}
  def generate_tenant_key(scope, <<_::128>> = key_id, purpose, kek_label)
      when purpose in [:data, :dek_wrap] and is_binary(kek_label) and kek_label != "" do
    key = Redacted.wrap(Relay.Random.bytes(@key_bytes))

    with {:ok, aad} <- kek_aad(scope, key_id, Atom.to_string(purpose)),
         {:ok,
          <<_::binary-size(@iv_bytes), _::binary-size(@key_bytes), _::binary-size(@tag_bytes)>> =
            wrapped} <- Relay.Keys.wrap(kek_label, aad, key) do
      {:ok, %{kek_ref: Relay.Keys.uri(kek_label), wrapped_key: <<@version, wrapped::binary>>}}
    else
      {:ok, _other} -> {:error, Error.new(:key_store_protocol, "unexpected wrapped key form")}
      {:error, error} -> {:error, error}
    end
  end

  # TN-33
  # OP-18
  @doc "Generates a subject data key for a retention class and wraps it under the tenant key `wrapping_key_id`. Returns the stored wrapped form to register and the data key, so the first fields can be encrypted before the record exists."
  @spec generate_subject_key(
          Relay.Scope.t(),
          Relay.Id.t(),
          Relay.Id.t(),
          Relay.RetentionClass.t()
        ) ::
          {:ok, %{wrapped_dek: binary(), data_key: Redacted.t()}} | {:error, Error.t()}
  def generate_subject_key(scope, <<_::128>> = wrapping_key_id, <<_::128>> = recipient_id, class) do
    with {:ok, class} <- Relay.RetentionClass.cast(class),
         {:ok, record} <- read(scope, fn -> Store.tenant_key(wrapping_key_id) end),
         {:ok, wrapping_key} <- tenant_key(scope, record, "dek_wrap") do
      class = Relay.RetentionClass.dump(class)
      dek = Relay.Random.bytes(@key_bytes)
      iv = Relay.Random.bytes(@iv_bytes)
      aad = dek_aad(scope, recipient_id, class, wrapping_key_id)
      {ciphertext, tag} = Relay.Crypto.aes_256_gcm_encrypt(wrapping_key, iv, dek, aad)
      wrapped = <<@version, iv::binary, ciphertext::binary, tag::binary>>
      {:ok, %{wrapped_dek: wrapped, data_key: Redacted.wrap(dek)}}
    end
  end

  defp macs([], _message, acc), do: {:ok, Enum.reverse(acc)}

  defp macs([key | keys], message, acc) do
    with {:ok, entry} <- mac(key, message), do: macs(keys, message, [entry | acc])
  end

  defp mac(%{id: id, hsm_ref: ref}, message) do
    with {:ok, label} <- Relay.Keys.label(ref),
         {:ok, mac} <- Relay.Keys.hmac_sha256(label, message),
         do: {:ok, {id, mac}}
  end

  defp field_key(scope, %{subject_id: <<_::128>> = subject, retention_class: class}) do
    with {:ok, class} <- Relay.RetentionClass.cast(class),
         do: subject_key(scope, subject, Relay.RetentionClass.dump(class))
  end

  defp field_key(scope, %{subject_id: nil, key_id: <<_::128>> = key_id}),
    do: tenant_data_key(scope, key_id)

  defp field_key(_scope, _field),
    do: {:error, Error.new(:invalid_scope, "invalid data key scope")}

  defp subject_key(scope, subject, class) do
    cached(scope, {:subject, subject, class}, &load_subject_key(scope, subject, class, &1))
  end

  defp load_subject_key(scope, subject, class, generation) do
    with {:ok, record} <- read(scope, fn -> Store.subject_key(subject, class) end),
         :ok <- usable(record["state"]),
         {:ok, wrapping_key} <- tenant_key(scope, wrapping(record), "dek_wrap", generation) do
      unwrap_dek(
        scope,
        record["wrapped_dek"],
        subject,
        class,
        record["wrapping_key_id"],
        wrapping_key
      )
    end
  end

  defp tenant_data_key(scope, key_id) do
    with {:ok, record} <- read(scope, fn -> Store.tenant_key(key_id) end),
         do: tenant_key(scope, record, "data")
  end

  defp tenant_key(scope, record, purpose, generation \\ :current)

  defp tenant_key(_scope, nil, _purpose, _generation), do: not_found()

  defp tenant_key(scope, %{"purpose" => purpose} = record, purpose, generation) do
    unwrap = fn _generation ->
      with :ok <- usable(record["state"]),
           {:ok, aad} <- kek_aad(scope, record["id"], purpose),
           {:ok, label} <- Relay.Keys.label(record["kek_ref"]),
           {:ok, wrapped} <- stored(record["wrapped_key"]) do
        Relay.Keys.unwrap(label, aad, wrapped)
      end
    end

    cached(scope, {:tenant, record["id"]}, unwrap, generation)
  end

  defp tenant_key(_scope, _record, _purpose, _generation),
    do: {:error, Error.new(:invalid_key_purpose, "tenant key has another purpose")}

  defp wrapping(record) do
    %{
      "id" => record["wrapping_key_id"],
      "purpose" => record["purpose"],
      "state" => record["wrapping_state"],
      "kek_ref" => record["kek_ref"],
      "wrapped_key" => record["wrapped_key"]
    }
  end

  defp unwrap_dek(scope, wrapped_dek, subject, class, wrapping_key_id, wrapping_key) do
    aad = dek_aad(scope, subject, class, wrapping_key_id)

    with {:ok, <<iv::binary-size(@iv_bytes), rest::binary>>} <- stored(wrapped_dek),
         <<ciphertext::binary-size(@key_bytes), tag::binary-size(@tag_bytes)>> <- rest,
         {:ok, dek} <- Relay.Crypto.aes_256_gcm_decrypt(wrapping_key, iv, ciphertext, aad, tag) do
      {:ok, Redacted.wrap(dek)}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:key_integrity, "data key failed authentication")}
    end
  end

  defp cached(scope, key, load, generation \\ :current) do
    key = {scope.tenant_id, scope.environment, key}

    case KeyCache.fetch(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        generation = if generation == :current, do: KeyCache.generation(), else: generation

        with {:ok, value} <- load.(generation) do
          _ = KeyCache.put(key, value, generation)
          {:ok, value}
        end
    end
  end

  defp read(scope, fun) do
    case Store.in_scope(scope, fn _status -> fun.() end) do
      {:ok, nil} -> not_found()
      {:ok, value} -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:database_error, "key record read failed")}
    end
  end

  # OP-17
  # OP-18
  defp usable("active"), do: :ok
  defp usable("retired"), do: :ok

  defp usable("restricted"),
    do: {:error, Error.new(:data_key_restricted, "data key is under statutory retention")}

  defp usable("destroyed"), do: {:error, Error.new(:data_key_destroyed, "data key destroyed")}
  defp usable(_state), do: not_found()

  defp stored(<<@version, wrapped::binary>>), do: {:ok, wrapped}
  defp stored(nil), do: {:error, Error.new(:data_key_destroyed, "data key destroyed")}
  defp stored(_other), do: {:error, Error.new(:invalid_wrapped_key, "unknown wrapped key form")}

  defp kek_aad(scope, <<_::128>> = key_id, purpose) do
    Relay.Canonical.encode([
      @version,
      {:bytes, scope.tenant_id},
      Relay.Environment.dump(scope.environment),
      {:bytes, key_id},
      purpose
    ])
  end

  defp dek_aad(scope, subject, class, wrapping_key_id) do
    Relay.Canonical.encode!([
      @version,
      {:bytes, scope.tenant_id},
      Relay.Environment.dump(scope.environment),
      {:bytes, subject},
      class,
      {:bytes, wrapping_key_id}
    ])
  end

  defp not_found, do: {:error, Error.new(:data_key_not_found, "data key not found")}
end
