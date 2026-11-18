defmodule Relay.Migration do
  @moduledoc """
  Moving from another notification system to Relay (OP-51 … OP-54, OP-79, OP-80, OP-94, OP-95). Other contexts use only the functions of this module.

    * Shadow comparison (`Relay.Migration.Shadow`): the existing system reports its decision per request, Relay compares it layer by layer with its own decision in shadow send mode, intentional differences explain what is meant to differ, and the coverage report says whether the exit criterion holds. The comparison data has its own retention class `shadow` and is crypto-shredded after 14 days (`Relay.Migration.ShadowKeys`, `Relay.Migration.KeySweep`).
    * Staged rollout (`Relay.Migration.Rollout`): a per tenant environment configuration routes each recipient to Relay or to the existing system by a sticky bucket, with an emergency stop that also opens an incident record; a recipient routed away is recorded skipped with `rollout.routed_to_legacy`.
    * Dual-send prevention: the existing system claims a dedup key before it sends (`claim/3`), and Relay's own send with a claimed key is recorded skipped with `dedup.claimed_by_legacy`; the SDKs report the digests of displayed notifications, from which the duplicate rate is measured (`Relay.Migration.Displayed`).
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Platform.Leadership,
      Relay.Platform.Maintenance,
      Relay.Tenancy,
      Relay.Subscribers,
      Relay.Keys.Eviction
    ],
    exports: [Content, Bucket, Routing, Ramp, Compare]

  alias Relay.Actor
  alias Relay.Migration.Displayed
  alias Relay.Migration.Rollout
  alias Relay.Migration.RolloutCache
  alias Relay.Migration.Shadow
  alias Relay.Migration.Store
  alias Relay.Scope

  @max_ttl_s Relay.Limits.seconds!(["shadow", "difference_max_ttl"])

  @doc "Supervised children: the node's rollout configuration cache."
  @spec children() :: [module()]
  def children, do: [RolloutCache]

  # OP-94
  @doc "Records the existing system's report of a request; see `Relay.Migration.Shadow.observe/2`."
  @spec observe(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate observe(scope, observation), to: Shadow

  # OP-94
  @doc "Records what a shadow send would have sent; see `Relay.Migration.Shadow.delivered/5`."
  @spec shadow_delivered(
          Scope.t(),
          Relay.Id.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  defdelegate shadow_delivered(scope, delivery_id, content_digest, provider, sender),
    to: Shadow,
    as: :delivered

  # OP-79
  # OP-94
  @doc "The shadow coverage report; see `Relay.Migration.Shadow.coverage/1`."
  @spec coverage(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate coverage(scope), to: Shadow

  # OP-79
  @doc "Intentional differences after a cursor identifier, newest first, at most `limit`."
  @spec differences(Scope.t(), Relay.Id.t() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def differences(%Scope{} = scope, after_id, limit),
    do: Store.in_scope(scope, fn _status -> Store.differences(after_id, limit) end)

  # OP-52 (3)
  # OP-79
  @doc "Records an intentional difference with its owner, reason and expiry of at most 30 days, audited; `{:error, :invalid_expiry}` outside that."
  @spec create_difference(Scope.t(), map(), Actor.t()) :: {:ok, map()} | {:error, term()}
  def create_difference(%Scope{} = scope, attrs, %Actor{} = actor) do
    digest = digest(scope, "shadow_difference.created", attrs.id)

    write = fn -> created(Store.difference_create(attrs, digest, actor)) end
    with :ok <- expiry(attrs.expires_at), do: written(scope, attrs.id, write)
  end

  # OP-79
  @doc "Moves the expiry of an intentional difference, audited; `{:error, :not_found}` or `{:error, :invalid_expiry}`."
  @spec renew_difference(Scope.t(), Relay.Id.t(), DateTime.t(), String.t(), Actor.t()) ::
          {:ok, map()} | {:error, term()}
  def renew_difference(%Scope{} = scope, id, expires_at, reason, %Actor{} = actor) do
    digest = digest(scope, "shadow_difference.renewed", id)

    write = fn -> renewed(Store.difference_renew(id, expires_at, reason, digest, actor)) end
    with :ok <- expiry(expires_at), do: written(scope, id, write)
  end

  # OP-95
  @doc "The stored rollout configuration of a scope, `nil` when none is set."
  @spec rollout(Scope.t()) :: {:ok, map() | nil} | {:error, term()}
  defdelegate rollout(scope), to: Rollout, as: :read

  # OP-53
  # OP-95
  @doc "Replaces the rollout configuration; see `Relay.Migration.Rollout.replace/3`."
  @spec replace_rollout(Scope.t(), map(), Actor.t()) :: {:ok, map()} | {:error, term()}
  defdelegate replace_rollout(scope, body, actor), to: Rollout, as: :replace

  # OP-53
  # OP-95
  @doc "The emergency stop of the rollout; see `Relay.Migration.Rollout.stop/3`."
  @spec stop_rollout(Scope.t(), String.t(), Actor.t()) :: {:ok, map()} | {:error, term()}
  defdelegate stop_rollout(scope, reason, actor), to: Rollout, as: :stop

  # OP-53
  @doc "Releases the emergency stop; see `Relay.Migration.Rollout.release/3`."
  @spec release_rollout(Scope.t(), String.t(), Actor.t()) :: {:ok, map()} | {:error, term()}
  defdelegate release_rollout(scope, reason, actor), to: Rollout, as: :release

  # OP-53
  # OP-95
  @doc "The external identifiers of a request's recipients that the rollout routes to the system being replaced; call it outside any transaction."
  @spec routed_to_legacy(Scope.t(), String.t() | nil, [String.t()]) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  defdelegate routed_to_legacy(scope, category, external_ids), to: Rollout, as: :legacy

  # OP-54
  # OP-95
  @doc "Claims a dedup key for the system being replaced for `ttl_s` seconds: `{:ok, {:claimed | :duplicate, claimed_by, expires_at}}`."
  @spec claim(Scope.t(), String.t(), pos_integer()) ::
          {:ok, {:claimed | :duplicate, String.t(), DateTime.t() | nil}} | {:error, term()}
  def claim(%Scope{} = scope, key, ttl_s),
    do: Store.in_scope(scope, fn _status -> Store.dedup_claim(key, ttl_s) end)

  # OP-54
  @doc "True while the system being replaced holds a claim on a dedup key; runs inside the caller's scoped transaction and locks the key until it ends."
  @spec claimed_here?(String.t() | nil) :: boolean()
  def claimed_here?(nil), do: false
  def claimed_here?(key) when is_binary(key), do: Store.dedup_claim_held?(key)

  # OP-54
  # OP-95
  @doc "Counts the displayed notification digests of a subscriber; see `Relay.Migration.Displayed.record/3`."
  @spec displayed(Scope.t(), Relay.Id.t(), [String.t()]) ::
          {:ok, %{accepted: non_neg_integer(), duplicates: non_neg_integer()}}
          | {:error, Relay.Error.t()}
  defdelegate displayed(scope, subscriber_id, digests), to: Displayed, as: :record

  # OP-52 (1)
  # OP-94
  @doc "Marks a webhook endpoint as the shadow endpoint or a live one, audited, inside the caller's scoped transaction."
  @spec set_webhook_shadow(Scope.t(), Relay.Id.t(), boolean(), Actor.t()) ::
          :set | :unchanged | :not_found | :archived
  def set_webhook_shadow(%Scope{} = scope, endpoint_id, shadow, %Actor{} = actor) do
    digest = digest(scope, "webhook_endpoint.updated", endpoint_id)
    Store.webhook_shadow_set(endpoint_id, shadow, digest, actor)
  end

  defp created(:invalid_expiry), do: {:error, :invalid_expiry}
  defp created(_created_or_exists), do: :ok

  defp renewed(:renewed), do: :ok
  defp renewed(refused), do: {:error, refused}

  defp written(scope, id, write) do
    work = fn _status ->
      with :ok <- write.(), do: {:ok, Store.difference(id)}
    end

    case Store.in_scope(scope, work) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp expiry(%DateTime{} = at) do
    seconds = DateTime.diff(at, Relay.Clock.utc_now())
    if seconds > 0 and seconds <= @max_ttl_s, do: :ok, else: {:error, :invalid_expiry}
  end

  defp digest(scope, action, id) do
    environment = Relay.Environment.dump(scope.environment)
    record = [action, {:bytes, scope.tenant_id}, environment, {:bytes, id}]
    :crypto.hash(:sha256, Relay.Canonical.encode!(record))
  end
end
