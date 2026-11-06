defmodule Relay.Secrets do
  @moduledoc """
  Secret references. The database keeps a reference and its version, never the secret: `${VAR}` names an environment variable of the node, `pkcs11:object=<label>` a secret data object in the key store. A secret is resolved only by the process that uses it, comes back as `Relay.Redacted` and is never cached in shared memory; a stored reference is read back only as its fingerprint, the HMAC-SHA256 of the secret under the installation's fingerprint key, computed inside the key store when it was registered. Resolving checks the fingerprint, so a secret that changed behind its reference is refused rather than used.

  Rotation registers the new reference and retires the old one in one transaction, then signals the tenant's `secrets` topic; processes holding the secret subscribe with `subscribe_rotations/1` and fetch it again, without a restart.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform], exports: [Ref]

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Secrets.Ref
  alias Relay.Secrets.Store

  @env ~r/\A\$\{([A-Z_][A-Z0-9_]{0,127})\}\z/
  @kinds [:provider_credential, :channel_identity, :webhook_signing]

  @type kind :: :provider_credential | :channel_identity | :webhook_signing
  @type source :: {:env, String.t()} | {:pkcs11, Relay.Keys.label()}

  # TN-26 (2)
  # TN-26 (4)
  @doc "Parses a secret reference: `${VAR}` or a PKCS#11 URI naming one object. A URI that carries a PIN or a password is refused."
  @spec parse(String.t()) :: {:ok, source()} | {:error, Error.t()}
  def parse("pkcs11:" <> _ = ref) do
    with {:ok, label} <- Relay.Keys.label(ref), do: {:ok, {:pkcs11, label}}
  end

  def parse(ref) when is_binary(ref) do
    case Regex.run(@env, ref) do
      [_, name] -> {:ok, {:env, name}}
      nil -> {:error, Error.new(:invalid_secret_ref, "a secret reference is ${VAR} or pkcs11:")}
    end
  end

  def parse(_ref), do: {:error, Error.new(:invalid_secret_ref, "not a secret reference")}

  # TN-26
  # INV-51
  @doc "Resolves a secret reference to its value, redacted."
  @spec resolve(String.t()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  def resolve(ref) do
    with {:ok, source} <- parse(ref), do: read(source)
  end

  # INV-51
  # TN-67 (4)
  @doc "The fingerprint of a secret: HMAC-SHA256 computed inside the key store under the installation's fingerprint key (`Relay.Keys.fingerprint_label/0`); the key never leaves the key store."
  @spec fingerprint(Redacted.t()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def fingerprint(secret) do
    with {:ok, label} <- Relay.Keys.fingerprint_label(),
         do: Relay.Keys.hmac_sha256(label, secret)
  end

  # TN-26 (2)
  # INV-51
  @doc "Registers a secret reference: resolves it once, records only its fingerprint and the reference. `attrs` carries `:id`, `:kind`, `:ref`, `:ref_version` and `:record_digest`."
  @spec register(Relay.Scope.t(), map(), Relay.Actor.t()) ::
          {:ok, :created | :exists} | {:error, Error.t()}
  def register(scope, %{kind: kind} = attrs, actor) when kind in @kinds do
    with {:ok, secret} <- resolve(attrs.ref),
         {:ok, fingerprint} <- fingerprint(secret) do
      in_scope(scope, fn -> Store.register(attrs, fingerprint, actor) end)
    end
  end

  # INV-51
  @doc "Reads a stored secret reference; only its fingerprint is returned, never the secret or the reference."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: {:ok, Ref.t()} | {:error, Error.t()}
  def get(scope, <<_::128>> = id) do
    with {:ok, {ref, _stored_ref}} <- in_scope(scope, fn -> Store.get(id) end), do: {:ok, ref}
  end

  # TN-26 (3)
  # INV-51
  @doc "Resolves the active secret of a stored reference for the calling process; a secret whose fingerprint no longer matches is refused."
  @spec fetch(Relay.Scope.t(), Relay.Id.t()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  def fetch(scope, <<_::128>> = id) do
    with {:ok, {%Ref{state: :active} = ref, stored_ref}} <-
           in_scope(scope, fn -> Store.get(id) end),
         {:ok, secret} <- resolve(stored_ref),
         {:ok, fingerprint} <- fingerprint(secret) do
      if Relay.Crypto.secure_compare(fingerprint, ref.fingerprint),
        do: {:ok, secret},
        else: {:error, Error.new(:secret_changed, "secret does not match its fingerprint")}
    else
      {:ok, {%Ref{}, _stored_ref}} ->
        {:error, Error.new(:secret_retired, "secret reference retired")}

      {:error, error} ->
        {:error, error}
    end
  end

  # TN-26 (5)
  @doc "Rotates a secret: registers `new` (attributes as for `register/3`) and retires `retire_id` in one transaction, then signals the holders. `retire_digest` is the audit record digest of the retirement."
  @spec rotate(Relay.Scope.t(), Relay.Id.t(), map(), binary(), Relay.Actor.t()) ::
          {:ok, :rotated} | {:error, Error.t()}
  def rotate(scope, <<_::128>> = retire_id, %{kind: kind} = new, retire_digest, actor)
      when kind in @kinds do
    with {:ok, secret} <- resolve(new.ref),
         {:ok, fingerprint} <- fingerprint(secret),
         {:ok, :rotated} <-
           in_scope(scope, fn ->
             Store.rotate(retire_id, new, fingerprint, retire_digest, actor)
           end) do
      _ = signal(scope, new.ref_version)
      {:ok, :rotated}
    end
  end

  # TN-26 (2)
  # INV-51
  @doc "Registers a secret reference of `kind` under a new identifier in its own scoped transaction and returns it; a secret already registered for this kind returns its existing active reference, so a retried request finds the same one. A retired secret is refused: a rotation needs a new secret."
  @spec register_ref(
          Relay.Scope.t(),
          kind(),
          String.t(),
          pos_integer(),
          binary(),
          Relay.Actor.t()
        ) :: {:ok, Ref.t()} | {:error, Error.t()}
  def register_ref(scope, kind, ref, ref_version, digest, actor) when kind in @kinds do
    attrs = %{
      id: Relay.Id.generate(),
      kind: kind,
      ref: ref,
      ref_version: ref_version,
      record_digest: digest
    }

    with {:ok, secret} <- resolve(ref),
         {:ok, fingerprint} <- fingerprint(secret) do
      in_scope(scope, fn ->
        {:ok, _created_or_exists} = Store.register(attrs, fingerprint, actor)
        registered(Store.find(Atom.to_string(kind), fingerprint))
      end)
    end
  end

  defp registered(%Ref{state: :active} = ref), do: {:ok, ref}
  defp registered(_ref), do: {:error, Error.new(:secret_retired, "secret reference retired")}

  # TN-26 (5)
  @doc "Retires a stored secret reference in its own scoped transaction; the holders are signalled with `signal_rotation/2` by the caller once the reference is no longer named."
  @spec retire(Relay.Scope.t(), Relay.Id.t(), binary(), Relay.Actor.t()) ::
          {:ok, :retired | :already_retired | :not_found} | {:error, Error.t()}
  def retire(scope, <<_::128>> = id, digest, actor),
    do: in_scope(scope, fn -> {:ok, Store.retire(id, digest, actor)} end)

  @doc "Like `retire/4`, inside the caller's scoped transaction."
  @spec retire(Relay.Id.t(), binary(), Relay.Actor.t()) ::
          :retired | :already_retired | :not_found
  def retire(<<_::128>> = id, digest, actor), do: Store.retire(id, digest, actor)

  # INV-51
  @doc "The stored secret references of `ids` by identifier, in their own scoped transaction; only fingerprints, versions and states are returned."
  @spec describe(Relay.Scope.t(), [Relay.Id.t()]) ::
          {:ok, %{Relay.Id.t() => Ref.t()}} | {:error, Error.t()}
  def describe(scope, ids), do: in_scope(scope, fn -> {:ok, describe(ids)} end)

  @doc "Like `describe/2`, inside the caller's scoped transaction."
  @spec describe([Relay.Id.t()]) :: %{Relay.Id.t() => Ref.t()}
  def describe(ids), do: ids |> Enum.uniq() |> Store.many() |> Map.new(&{&1.id, &1})

  # TN-26 (5)
  @doc "Signals the holders of a tenant environment's secrets that a reference changed; they fetch their secret again."
  @spec signal_rotation(Relay.Scope.t(), pos_integer()) :: :ok | {:error, Error.t()}
  def signal_rotation(scope, version), do: signal(scope, version)

  # TN-26 (5)
  @doc "Subscribes the calling process to the rotations of a tenant environment's secrets; it receives `{:relay_signal, topic, event}` after each rotation and fetches its secret again."
  @spec subscribe_rotations(Relay.Scope.t()) :: :ok | {:error, Error.t()}
  def subscribe_rotations(scope) do
    with {:ok, topic} <- topic(scope), do: Relay.Platform.subscribe_signal(topic)
  end

  @doc "The signal topic of a tenant environment's secret rotations."
  @spec topic(Relay.Scope.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def topic(scope) do
    Relay.Platform.signal_topic(
      Relay.Scope.tenant_text(scope),
      Relay.Environment.dump(scope.environment),
      ["secrets"]
    )
  end

  defp signal(scope, version) do
    with {:ok, topic} <- topic(scope), do: Relay.Platform.publish_signal(topic, version)
  end

  defp read({:env, name}) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, Redacted.wrap(value)}
      _ -> {:error, Error.new(:secret_unavailable, "secret reference does not resolve")}
    end
  end

  defp read({:pkcs11, label}), do: Relay.Keys.read_secret(label)

  defp in_scope(scope, fun) do
    case Store.in_scope(scope, fn _status -> fun.() end) do
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:ok, result} -> result
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:database_error, "secret reference query failed")}
    end
  end
end
