defmodule Relay.Tenancy.KeyCustody do
  @moduledoc """
  A tenant's own key in the region's key store (bring your own key). The key is a key object dedicated to the tenant in the region's PKCS#11 token, named by its URI `pkcs11:token=…;object=…`; Relay never sees the key itself. Once set, the tenant's keys of both environments are wrapped under it instead of the region KEK: setting or changing it records the reference with an audit record in the tenant's `live` environment and then wraps every tenant key that is not destroyed again, each environment in one transaction after the key store calls. Keys created later for the tenant are wrapped under it as well.

  When the key store cannot reach the tenant's key (the object is missing, or the token is gone) every read that needs one of the tenant's keys fails closed with `key_unavailable` and the `[:relay, :keys, :custody_unavailable]` event raises the alarm. A tenant that destroys its key in the key store crypto-shreds its own data: nothing wrapped under it can be read again.
  """

  alias Relay.Actor
  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Scope
  alias Relay.Tenancy.Context
  alias Relay.Tenancy.Keyring
  alias Relay.Tenancy.Store

  @environments [:live, :test]
  @probe_aad "relay-key-custody-probe-v1"
  @version 1

  @type key_reference :: %{token: String.t(), label: Relay.Keys.label()}
  @type outcome :: %{
          key_ref: String.t(),
          result: :changed | :unchanged,
          rewrapped: non_neg_integer()
        }

  # OP-85
  # TN-63
  @doc "Checks a tenant key reference against the token the key store opens (`token`, `nil` when none is configured on this node): both the token and the object are named, the token is the region's own and the object is none of the installation's configured keys."
  @spec check(String.t(), String.t() | nil) :: {:ok, key_reference()} | {:error, Error.t()}
  def check(key_ref, token) when is_binary(key_ref) do
    with {:ok, ref} <- Relay.Keys.reference(key_ref),
         :ok <- same_token(ref.token, token),
         do: dedicated(ref)
  end

  def check(_key_ref, _token),
    do: {:error, Error.new(:invalid_key_ref, "a key reference is a PKCS#11 URI")}

  defp same_token(_given, nil), do: :ok
  defp same_token(token, token), do: :ok

  defp same_token(_given, _token),
    do: {:error, Error.new(:invalid_key_ref, "the key is not in the region's key store")}

  defp dedicated(ref) do
    configured = [
      Relay.Keys.kek_label(),
      Relay.Keys.fingerprint_label(),
      Relay.Keys.cursor_label()
    ]

    installation = for {:ok, label} <- configured, do: label

    if ref.label in installation,
      do: {:error, Error.new(:invalid_key_ref, "the key is one of the installation's keys")},
      else: {:ok, ref}
  end

  # OP-85
  # TN-27
  # TN-21
  @doc "Sets or changes the tenant's own key and wraps the tenant's keys under it; `digest` is the digest of the `tenant.key_custody_changed` audit record of the tenant's `live` environment with the reference as its reason. The key is probed first; a key the key store cannot use is refused with `key_unavailable` and nothing changes. Returns the stored reference, whether it changed and how many keys were wrapped again."
  @spec set(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:ok, outcome()} | {:error, Error.t()}
  def set(<<_::128>> = tenant_id, key_ref, <<_::256>> = digest, %Actor{} = actor) do
    live = Scope.new!(tenant_id, :live)

    with {:ok, ref} <- check(key_ref, Relay.Keys.token()),
         :ok <- probe(live, ref.label),
         {:ok, result} <- record(live, key_ref, digest, actor),
         {:ok, rewrapped} <- rewrap_all(tenant_id, key_ref, ref.label) do
      {:ok, %{key_ref: key_ref, result: result, rewrapped: rewrapped}}
    end
  end

  defp record(scope, key_ref, digest, actor) do
    case Context.within(scope, fn _status ->
           Store.tenant_key_custody_set(key_ref, digest, actor)
         end) do
      {:ok, :tenant_closed} -> {:error, Error.new(:tenant_closed, "the tenant is closed")}
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:database_error, "key custody write failed")}
    end
  end

  # OP-85
  @doc "Wraps every tenant key of both environments that is not destroyed and not yet under `key_ref` again under the key `label`; returns how many changed. A run can be repeated: keys already under the reference are left alone."
  @spec rewrap_all(Relay.Id.t(), String.t(), Relay.Keys.label()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def rewrap_all(<<_::128>> = tenant_id, key_ref, label) do
    Enum.reduce_while(@environments, {:ok, 0}, fn environment, {:ok, total} ->
      case rewrap(Scope.new!(tenant_id, environment), key_ref, label) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp rewrap(scope, key_ref, label) do
    with {:ok, keys} <- read(scope, &Store.unshredded_tenant_keys/0),
         pending = Enum.reject(keys, &(&1["kek_ref"] == key_ref)),
         {:ok, changes} <- wrapped_again(scope, pending, label) do
      apply_changes(scope, changes, key_ref)
    end
  end

  defp wrapped_again(scope, keys, label) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case wrap_again(scope, key, label) do
        {:ok, change} -> {:cont, {:ok, [change | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp wrap_again(scope, %{"id" => id, "purpose" => purpose} = key, label) do
    with {:ok, aad} <- Keyring.tenant_key_aad(scope, id, purpose),
         {:ok, old_label} <- Relay.Keys.label(key["kek_ref"]),
         {:ok, wrapped} <- stored(key["wrapped_key"]),
         {:ok, plain} <- available(scope, old_label, Relay.Keys.unwrap(old_label, aad, wrapped)),
         {:ok, again} <- available(scope, label, Relay.Keys.wrap(label, aad, plain)) do
      {:ok, {id, key["kek_ref"], <<@version, again::binary>>}}
    end
  end

  defp stored(<<@version, wrapped::binary>>), do: {:ok, wrapped}
  defp stored(_other), do: {:error, Error.new(:invalid_wrapped_key, "unknown wrapped key form")}

  defp apply_changes(_scope, [], _key_ref), do: {:ok, 0}

  defp apply_changes(scope, changes, key_ref) do
    result =
      Context.within(scope, fn _status ->
        results =
          for {id, expected, wrapped} <- Enum.reverse(changes),
              do: Store.tenant_key_rewrap(id, expected, key_ref, wrapped)

        if :conflict in results,
          do: Store.rollback(:conflict),
          else: Enum.count(results, &(&1 == :rewrapped))
      end)

    case result do
      {:ok, count} ->
        {:ok, count}

      {:error, :conflict} ->
        {:error, Error.new(:resource_conflict, "a tenant key changed while it was wrapped again")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, Error.new(:database_error, "tenant key rewrap failed")}
    end
  end

  # OP-85
  @doc "Reads the tenant's own key reference, `nil` when its keys are wrapped under the region KEK, together with how many of its keys of both environments are wrapped under it and under another key."
  @spec show(Relay.Id.t()) ::
          {:ok, %{key_ref: String.t() | nil, keys: non_neg_integer(), other: non_neg_integer()}}
          | {:error, Error.t()}
  def show(<<_::128>> = tenant_id) do
    with {:ok, tenant} <- read(Scope.new!(tenant_id, :live), &Store.tenant/0),
         {:ok, keys} <- all_keys(tenant_id) do
      key_ref = tenant["key_ref"]
      under = Enum.count(keys, &(&1["kek_ref"] == key_ref and key_ref != nil))
      {:ok, %{key_ref: key_ref, keys: under, other: length(keys) - under}}
    end
  end

  defp all_keys(tenant_id) do
    Enum.reduce_while(@environments, {:ok, []}, fn environment, {:ok, acc} ->
      case read(Scope.new!(tenant_id, environment), &Store.unshredded_tenant_keys/0) do
        {:ok, keys} -> {:cont, {:ok, acc ++ keys}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # OP-85
  # TN-27
  @doc "The key store label and reference new keys of `scope`'s tenant are wrapped under: the tenant's own key when it has one, otherwise the region KEK `region_label`."
  @spec wrapping(Scope.t(), Relay.Keys.label()) ::
          {:ok, {Relay.Keys.label(), String.t()}} | {:error, Error.t()}
  def wrapping(%Scope{} = scope, region_label) when is_binary(region_label) do
    case read(Scope.new!(scope.tenant_id, :live), &Store.tenant/0) do
      {:ok, %{"key_ref" => key_ref}} when is_binary(key_ref) ->
        with {:ok, label} <- Relay.Keys.label(key_ref), do: {:ok, {label, key_ref}}

      {:ok, _tenant} ->
        {:ok, {region_label, Relay.Keys.uri(region_label)}}

      {:error, error} ->
        {:error, error}
    end
  end

  # OP-85
  @doc "Turns a key store answer for the key `label` into `key_unavailable` when the key store cannot reach a tenant's own key (the object or the token is gone), and raises the alarm; the region KEK and other answers pass unchanged."
  @spec available(Scope.t(), Relay.Keys.label(), result) :: result
        when result: {:ok, term()} | {:error, Error.t()}
  def available(scope, label, {:error, %Error{code: code}} = error)
      when code in [:key_not_found, :key_store_token] do
    if Relay.Keys.kek_label() == {:ok, label} do
      error
    else
      :telemetry.execute([:relay, :keys, :custody_unavailable], %{count: 1}, %{
        tenant_id: Scope.tenant_text(scope)
      })

      {:error, Error.new(:key_unavailable, "the tenant's own key is unavailable")}
    end
  end

  def available(_scope, _label, result), do: result

  defp probe(scope, label) do
    key = Redacted.wrap(Relay.Random.bytes(32))

    with {:ok, wrapped} <- available(scope, label, Relay.Keys.wrap(label, @probe_aad, key)),
         {:ok, back} <- available(scope, label, Relay.Keys.unwrap(label, @probe_aad, wrapped)) do
      if Redacted.expose(back) == Redacted.expose(key),
        do: :ok,
        else: {:error, Error.new(:key_unavailable, "the tenant's own key failed the probe")}
    end
  end

  defp read(scope, fun) do
    case Context.within(scope, fn _status -> fun.() end) do
      {:ok, nil} -> {:error, Error.new(:tenant_not_found, "no such tenant")}
      {:ok, value} -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:database_error, "tenant key read failed")}
    end
  end
end
