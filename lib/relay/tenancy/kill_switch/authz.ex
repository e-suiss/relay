defmodule Relay.Tenancy.KillSwitch.Authz do
  @moduledoc """
  Who may change a kill switch, a pure function that runs before the database (TN-41, TN-70 (1)); the database `CHECK` constraints are the second defence. The scope sets the lowest role: campaign and workflow need a tenant operator, the tenant and its sub-tenant, API client and sender scopes a tenant administrator (S-51), the platform scope the installation operator; the roles rank `installation_operator > tenant_admin > tenant_operator` (TN-23).

  Relaxing a kill switch, that is releasing it, replacing it by a weaker one or resuming its paused deliveries, needs an explicit approval reference; in stage 3 step-up replaces that flag (TN-22). Stopping `security` messages needs its own approval (TN-42) and a record without an expiry its own approval too. Until stage 3 brings RBAC the installation operator is the only actor (TN-70 (1)).
  """

  @type actor_kind :: :installation_operator | :tenant_admin | :tenant_operator
  @type actor :: %{kind: actor_kind(), ref: String.t()}
  @type action :: :engage | :replace | :release | :resume | :bulk_cancel
  @type spec :: %{
          optional(:scope_kind) => atom(),
          optional(:reason) => String.t() | nil,
          optional(:message_class) => String.t() | atom() | nil,
          optional(:security_approval) => String.t() | nil,
          optional(:expires_at) => DateTime.t() | nil,
          optional(:no_ttl_approval) => String.t() | nil,
          optional(:relaxes?) => boolean(),
          optional(:relax_approval) => String.t() | nil
        }
  @type reason ::
          :actor_not_supported
          | :forbidden
          | :reason_required
          | :relax_approval_required
          | :security_approval_required
          | :no_ttl_approval_required

  @rank %{installation_operator: 3, tenant_admin: 2, tenant_operator: 1}
  @minimum %{
    campaign: :tenant_operator,
    workflow: :tenant_operator,
    tenant: :tenant_admin,
    subtenant: :tenant_admin,
    api_client: :tenant_admin,
    sender: :tenant_admin,
    platform: :installation_operator
  }
  @stage_actors [:installation_operator]

  # TN-41
  # TN-42
  # TN-70 (1)
  # TN-22
  # TN-23
  @doc "Authorizes `action` on the kill switch described by `spec` for `actor`."
  @spec authorize(actor(), action(), spec()) :: :ok | {:error, reason()}
  def authorize(%{kind: kind, ref: ref}, action, spec)
      when is_map_key(@rank, kind) and is_binary(ref) and
             action in [:engage, :replace, :release, :resume, :bulk_cancel] and is_map(spec) do
    [
      {:actor_not_supported, kind not in @stage_actors},
      {:forbidden, not allowed_role?(kind, Map.get(spec, :scope_kind))},
      {:reason_required, blank?(Map.get(spec, :reason))},
      {:relax_approval_required,
       relaxing?(action, spec) and blank?(Map.get(spec, :relax_approval))},
      {:security_approval_required, security?(action, spec)},
      {:no_ttl_approval_required, no_ttl?(action, spec)}
    ]
    |> Enum.find_value(:ok, fn {reason, failed?} -> if failed?, do: {:error, reason} end)
  end

  def authorize(_actor, _action, _spec), do: {:error, :actor_not_supported}

  @doc "Lowest role that may change a kill switch of `scope_kind`."
  @spec minimum_role(atom()) :: actor_kind()
  def minimum_role(scope_kind), do: Map.fetch!(@minimum, scope_kind)

  # TN-41
  # TN-23
  @doc "Returns true if a role of `kind` reaches the lowest role of `scope_kind`."
  @spec allowed_role?(actor_kind(), atom()) :: boolean()
  def allowed_role?(kind, scope_kind)
      when is_map_key(@rank, kind) and is_map_key(@minimum, scope_kind),
      do: @rank[kind] >= @rank[@minimum[scope_kind]]

  def allowed_role?(_kind, _scope_kind), do: false

  # TN-22
  # TN-70 (1)
  @doc """
  Returns true if replacing `old` by a record with `new`'s `:state`, `:canary_percent`, `:paused_until` and `:expires_at` relaxes it: a lower state rank (`off` 3, `paused_until` 2, `canary` 1, `on` 0) or, at the same rank, an earlier `paused_until`, a higher canary percent or an earlier expiry.
  """
  @spec relaxes?(map(), map()) :: boolean()
  def relaxes?(old, new) do
    old_rank = rank(old.state)
    new_rank = rank(new.state)

    new_rank < old_rank or
      (new_rank == old_rank and
         (earlier_pause?(new, old) or higher_canary?(new, old) or earlier_expiry?(new, old)))
  end

  defp rank(:off), do: 3
  defp rank(:paused_until), do: 2
  defp rank(:canary), do: 1
  defp rank(:on), do: 0

  defp earlier_pause?(%{state: :paused_until, paused_until: %DateTime{} = new}, old) do
    case old.paused_until do
      nil -> true
      %DateTime{} = previous -> DateTime.compare(new, previous) == :lt
    end
  end

  defp earlier_pause?(_new, _old), do: false

  defp higher_canary?(%{state: :canary, canary_percent: new}, %{canary_percent: old}),
    do: new > old

  defp higher_canary?(_new, _old), do: false

  defp earlier_expiry?(%{expires_at: nil}, _old), do: false
  defp earlier_expiry?(%{expires_at: _new}, %{expires_at: nil}), do: true

  defp earlier_expiry?(%{expires_at: new}, %{expires_at: old}),
    do: DateTime.compare(new, old) == :lt

  defp relaxing?(action, _spec) when action in [:release, :resume], do: true
  defp relaxing?(:replace, spec), do: Map.get(spec, :relaxes?, false)
  defp relaxing?(_action, _spec), do: false

  defp security?(:engage, spec),
    do:
      to_string(Map.get(spec, :message_class)) == "security" and
        blank?(Map.get(spec, :security_approval))

  defp security?(_action, _spec), do: false

  defp no_ttl?(action, spec) when action in [:engage, :replace],
    do: is_nil(Map.get(spec, :expires_at)) and blank?(Map.get(spec, :no_ttl_approval))

  defp no_ttl?(_action, _spec), do: false

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: true
end
