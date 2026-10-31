defmodule Relay.Operators.Authz do
  @moduledoc """
  Who may run an operator operation, a pure function of the operator's role grants and the operation (TN-19, TN-22, TN-23, X-3, X-4). Roles are Relay's own records, never an identity provider claim (E-63); they rank `installation_operator 3 > tenant_admin 2 > tenant_operator 1`.

  * An operation without a role needs only a valid session.
  * An installation operation needs the `installation_operator` grant of the installation tenant's `live` environment.
  * A tenant operation needs a grant of the selected tenant and environment whose rank reaches the operation's role. In the installation tenant the installation operator ranks above every tenant role; in any other tenant the installation operator holds no tenant role and cannot read past row level security (TN-23): with an active support delegation of that tenant and environment it may run reading operations only, on the tenant's behalf, and never reveal personal data.
  """

  @type role :: :installation_operator | :tenant_admin | :tenant_operator
  @type grant :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => :live | :test,
          required(:role) => role(),
          optional(:role_assignment_id) => Relay.Id.t()
        }
  @type context :: %{
          required(:installation_tenant_id) => Relay.Id.t(),
          required(:scope) => Relay.Scope.t() | nil,
          optional(:delegation_id) => Relay.Id.t() | nil,
          optional(:reads?) => boolean(),
          optional(:reveal?) => boolean()
        }
  @type decision ::
          {:ok, :own | {:delegated, Relay.Id.t()}}
          | {:error, :insufficient_role | :delegation_required,
             %{required: role(), granted: [role()]}}

  @rank %{installation_operator: 3, tenant_admin: 2, tenant_operator: 1}

  # TN-23
  @doc "Returns the rank of a role."
  @spec rank(role()) :: 1..3
  def rank(role), do: Map.fetch!(@rank, role)

  @doc "Returns the built-in roles in rank order, highest first."
  @spec roles() :: [role(), ...]
  def roles, do: [:installation_operator, :tenant_admin, :tenant_operator]

  # TN-19
  # TN-23
  # X-4
  @doc "Authorizes an operation that needs `role` (or `nil`) for an operator holding `grants` in `context`."
  @spec authorize([grant()], role() | nil, context()) :: decision()
  def authorize(_grants, nil, _context), do: {:ok, :own}

  def authorize(grants, :installation_operator, %{installation_tenant_id: installation}) do
    if installation_operator?(grants, installation),
      do: {:ok, :own},
      else: {:error, :insufficient_role, %{required: :installation_operator, granted: []}}
  end

  def authorize(grants, role, %{scope: %Relay.Scope{} = scope} = context) do
    granted = granted(grants, scope, context.installation_tenant_id)
    best = granted |> Enum.map(&rank/1) |> Enum.max(fn -> 0 end)

    cond do
      best >= rank(role) ->
        {:ok, :own}

      delegated?(grants, context) ->
        {:ok, {:delegated, context.delegation_id}}

      installation_operator?(grants, context.installation_tenant_id) and
          is_nil(Map.get(context, :delegation_id)) ->
        {:error, :delegation_required, %{required: role, granted: granted}}

      true ->
        {:error, :insufficient_role, %{required: role, granted: granted}}
    end
  end

  def authorize(_grants, role, _context),
    do: {:error, :insufficient_role, %{required: role, granted: []}}

  @doc "Returns the roles the grants give in a tenant scope; the installation operator counts only in the installation tenant's `live` environment."
  @spec granted([grant()], Relay.Scope.t(), Relay.Id.t()) :: [role()]
  def granted(grants, %Relay.Scope{} = scope, installation) do
    for %{tenant_id: tenant, environment: environment, role: role} <- grants,
        tenant == scope.tenant_id and environment == scope.environment,
        role != :installation_operator or tenant == installation,
        uniq: true,
        do: role
  end

  # TN-23
  @doc "Returns true if the grants hold the installation operator role."
  @spec installation_operator?([grant()], Relay.Id.t()) :: boolean()
  def installation_operator?(grants, installation) do
    Enum.any?(grants, fn grant ->
      grant.role == :installation_operator and grant.tenant_id == installation and
        grant.environment == :live
    end)
  end

  defp delegated?(grants, context) do
    is_binary(Map.get(context, :delegation_id)) and Map.get(context, :reads?, false) and
      not Map.get(context, :reveal?, false) and
      installation_operator?(grants, context.installation_tenant_id)
  end

  # TN-22
  @doc """
  Returns true if a send mode change relaxes: the new mode is closer to `live` (`off < dry_run < shadow < live`); clearing a level falls back to `live`.
  """
  @spec send_mode_relaxes?(String.t() | nil, String.t() | nil) :: boolean()
  def send_mode_relaxes?(previous, new), do: mode_rank(new) > mode_rank(previous)

  # TN-22
  # API-51
  @doc """
  Returns true if a quota policy change relaxes: removing an active policy, raising its limit or its `security` reserve, or raising or dropping a class cap. Creating a policy where none is active only tightens. `current` and `new` carry `:limit_total` (`nil` for no active policy), `:class_caps` and `:security_reserve_bp`.
  """
  @spec quota_relaxes?(map(), map()) :: boolean()
  def quota_relaxes?(%{limit_total: nil}, _new), do: false
  def quota_relaxes?(_current, %{limit_total: nil}), do: true

  def quota_relaxes?(current, new) do
    new.limit_total > current.limit_total or
      new.security_reserve_bp > current.security_reserve_bp or
      Enum.any?(current.class_caps, fn {class, cap} ->
        not Map.has_key?(new.class_caps, class) or Map.fetch!(new.class_caps, class) > cap
      end)
  end

  defp mode_rank("off"), do: 0
  defp mode_rank("dry_run"), do: 1
  defp mode_rank("shadow"), do: 2
  defp mode_rank(_live_or_nil), do: 3
end
