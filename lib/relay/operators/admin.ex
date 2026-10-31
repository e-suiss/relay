defmodule Relay.Operators.Admin do
  @moduledoc """
  The management actions of operators, each written with its audit record in one transaction (TN-47, TN-48): role assignments (TN-21, TN-23), support delegations (TN-23), the cross-tenant overview (X-4), the audit log (TN-50), the audited reveal of personal data (X-5), send modes (OP-51) and the API version pin (API-52). The caller has authorized the action and, for a sensitive one, passed its step-up reference.
  """

  alias Relay.Actor
  alias Relay.Operators
  alias Relay.Operators.Authz
  alias Relay.Operators.Store
  alias Relay.Scope

  @delegation_default_s Relay.Limits.seconds!(["support_delegation", "default"])
  @delegation_min_s Relay.Limits.seconds!(["support_delegation", "min"])
  @delegation_max_s Relay.Limits.seconds!(["support_delegation", "max"])
  @delegation_min Relay.Limits.fetch!(["support_delegation", "min"])
  @delegation_max Relay.Limits.fetch!(["support_delegation", "max"])
  @delegation_range "the duration is #{@delegation_min} to #{@delegation_max}"

  # TN-21
  # TN-23
  @doc "Assigns `role` to an operator in `scope`; returns the stored assignment."
  @spec assign_role(Scope.t(), map(), Actor.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def assign_role(%Scope{} = scope, attrs, %Actor{} = actor, step_up_ref) do
    id = Relay.Id.generate()
    target = Relay.Id.to_string(id)
    digest = digest(scope, "role_assignment.created", actor, "role_assignment", target, attrs)

    Store.in_scope(scope, fn _status ->
      record = Map.merge(attrs, %{id: id, step_up_ref: step_up_ref})

      case Store.role_assign(record, digest, actor) do
        {:assigned, id} ->
          {:ok, Store.role_get(id)}

        {:exists, _id} ->
          {:error, conflict("the operator already holds this role")}

        {:operator_not_found, _} ->
          {:error, operator_not_found()}

        {:operator_inactive, _} ->
          {:error, operator_not_found()}

        {:role_not_allowed, _} ->
          {:error, field("/role", "unsupported_value", "role not allowed")}
      end
    end)
    |> unwrap()
  end

  # TN-21
  @doc "Revokes a role assignment of `scope`; the last tenant administrator cannot be revoked."
  @spec revoke_role(Scope.t(), Relay.Id.t(), String.t(), Actor.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def revoke_role(%Scope{} = scope, id, reason, %Actor{} = actor, step_up_ref) do
    target = Relay.Id.to_string(id)
    digest = digest(scope, "role_assignment.revoked", actor, "role_assignment", target, reason)

    Store.in_scope(scope, fn _status ->
      case Store.role_revoke(id, reason, step_up_ref, digest, actor) do
        :revoked -> {:ok, Store.role_get(id)}
        :not_found -> {:error, Relay.Error.new(:role_assignment_not_found, "no such assignment")}
        :already_revoked -> {:error, conflict("the assignment is already revoked")}
        :last_admin -> {:error, conflict("the last tenant administrator cannot be revoked")}
      end
    end)
    |> unwrap()
  end

  @doc "Lists the role assignments of `scope`."
  @spec role_assignments(Scope.t(), Relay.Id.t() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def role_assignments(%Scope{} = scope, after_id, limit),
    do: Store.in_scope(scope, fn _status -> Store.role_list(after_id, limit) end)

  # TN-23
  @doc """
  Grants an installation operator time-limited, read-only access to `scope` on the tenant's behalf. `duration_s` defaults to the contract's `support_delegation.default` and lies between its `min` and `max`.
  """
  @spec grant_delegation(Scope.t(), map(), Actor.t(), String.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def grant_delegation(%Scope{} = scope, attrs, %Actor{} = actor, step_up_ref) do
    duration = Map.get(attrs, :duration_s) || @delegation_default_s

    cond do
      duration < @delegation_min_s or duration > @delegation_max_s ->
        {:error, field("/duration", "unsupported_value", @delegation_range)}

      not installation_operator?(attrs.operator_id) ->
        {:error, field("/operator_id", "not_allowed", "not an installation operator")}

      true ->
        write_delegation(scope, attrs, duration, actor, step_up_ref)
    end
  end

  defp installation_operator?(operator_id) do
    Authz.installation_operator?(
      Operators.grants(operator_id),
      Operators.installation_tenant_id()
    )
  end

  defp write_delegation(scope, attrs, duration, actor, step_up_ref) do
    id = Relay.Id.generate()
    target = Relay.Id.to_string(id)

    digest =
      digest(scope, "support_delegation.granted", actor, "support_delegation", target, attrs)

    record = %{
      id: id,
      operator_id: attrs.operator_id,
      reason: attrs.reason,
      expires_at: DateTime.add(Relay.Clock.utc_now(), duration, :second),
      step_up_ref: step_up_ref
    }

    Store.in_scope(scope, fn _status ->
      case Store.delegation_grant(record, digest, actor) do
        {:granted, id} -> {:ok, Store.delegation_get(id)}
        {:operator_not_found, _} -> {:error, operator_not_found()}
        {:not_installation_operator, _} -> {:error, operator_not_found()}
        {:duration_invalid, _} -> {:error, field("/duration", "unsupported_value", "invalid")}
      end
    end)
    |> unwrap()
  end

  @doc "Revokes a support delegation of `scope` at once."
  @spec revoke_delegation(Scope.t(), Relay.Id.t(), String.t(), Actor.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def revoke_delegation(%Scope{} = scope, id, reason, %Actor{} = actor) do
    target = Relay.Id.to_string(id)

    digest =
      digest(scope, "support_delegation.revoked", actor, "support_delegation", target, reason)

    Store.in_scope(scope, fn _status ->
      case Store.delegation_revoke(id, reason, digest, actor) do
        :revoked -> {:ok, Store.delegation_get(id)}
        :not_found -> {:error, Relay.Error.new(:support_delegation_not_found, "no delegation")}
        :already_ended -> {:error, conflict("the delegation has ended")}
      end
    end)
    |> unwrap()
  end

  @doc "Lists the support delegations of `scope`, only those of `operator_id` when given."
  @spec delegations(Scope.t(), Relay.Id.t() | nil, Relay.Id.t() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def delegations(%Scope{} = scope, operator_id, after_id, limit),
    do:
      Store.in_scope(scope, fn _status -> Store.delegation_list(operator_id, after_id, limit) end)

  # X-4
  # TN-23
  @doc """
  The cross-tenant overview: installation-level facts and counters per tenant, never tenant record content. Every query writes `cross_tenant.queried` in the installation scope.
  """
  @spec tenants(Actor.t(), map()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def tenants(%Actor{} = actor, query) do
    with :ok <- cross_tenant_audit(actor, query[:tenant_id], query[:status]) do
      case query[:tenant_id] do
        nil ->
          {:ok, Store.overview(query[:status], query[:after_id], query[:limit] || 50)}

        <<n::128>> = id ->
          before = <<n - 1::128>>
          {:ok, Enum.filter(Store.overview(nil, before, 1), &(&1["id"] == id))}
      end
    end
  end

  defp cross_tenant_audit(actor, tenant_id, status) do
    scope = Operators.installation_scope()
    target = if tenant_id, do: Relay.Id.to_string(tenant_id)
    reason = if status, do: "status=" <> status

    digest =
      Operators.record_digest(scope, "cross_tenant.queried", actor, "tenant", target, reason)

    record = %{action: "cross_tenant.queried", target_type: "tenant", target_id: target}
    record = Map.put(record, :reason, reason)

    case Store.in_scope(scope, fn _status -> Store.audit(record, digest, actor) end) do
      {:ok, _id} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # TN-50
  @doc "Reads the audit log of `scope`; the read is audited (`audit_log.read`)."
  @spec audit_log(Scope.t(), map(), Actor.t()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def audit_log(%Scope{} = scope, query, %Actor{} = actor) do
    digest = Operators.record_digest(scope, "audit_log.read", actor, "audit_log", nil, nil)
    Store.in_scope(scope, fn _status -> Store.audit_query(query, digest, actor) end)
  end

  # X-5
  # TN-21
  # TN-47
  @doc """
  Reveals personal fields of a subscriber of `scope`: one `pii.revealed` audit record per field is written before any value is read, in the same transaction. Fields Relay holds no value for come back `nil`.
  """
  @spec reveal(Scope.t(), Relay.Id.t(), [String.t()], String.t(), Actor.t()) ::
          {:ok, %{fields: map(), audit_ids: [Relay.Id.t()]}} | {:error, Relay.Error.t()}
  def reveal(%Scope{} = scope, subscriber_id, fields, reason, %Actor{} = actor) do
    target = Relay.Id.to_string(subscriber_id)

    Store.in_scope(scope, fn _status ->
      if Store.subscriber?(subscriber_id) do
        ids = Enum.map(fields, &reveal_audit(scope, target, &1, reason, actor))
        {:ok, %{fields: Map.new(fields, &{&1, nil}), audit_ids: ids}}
      else
        {:error, Relay.Error.new(:subscriber_not_found, "no such subscriber")}
      end
    end)
    |> unwrap()
  end

  defp reveal_audit(scope, target, field, reason, actor) do
    reason = field <> ": " <> reason
    digest = Operators.record_digest(scope, "pii.revealed", actor, "subscriber", target, reason)
    record = %{action: "pii.revealed", target_type: "subscriber", target_id: target}
    Store.audit(Map.put(record, :reason, reason), digest, actor)
  end

  # OP-51
  @doc "Lists the send mode levels of `scope` and the installation default."
  @spec send_modes(Scope.t()) ::
          {:ok, %{levels: [map()], default: map() | nil}} | {:error, term()}
  def send_modes(%Scope{} = scope) do
    installation = Operators.installation_scope()

    with {:ok, levels} <- Store.in_scope(scope, fn _status -> Store.send_modes() end),
         {:ok, defaults} <- Store.in_scope(installation, fn _status -> Store.send_modes() end) do
      default = Enum.find(defaults, &(&1["key"] == "send_mode"))
      {:ok, %{levels: levels, default: default}}
    end
  end

  # OP-51
  # TN-22
  @doc """
  Checks a send mode change without writing it: `{:ok, relaxes?}`, where a relaxation moves the level closer to `live` and needs step-up.
  """
  @spec send_mode_relaxes(Scope.t(), map()) :: {:ok, boolean()} | {:error, term()}
  def send_mode_relaxes(%Scope{} = scope, attrs) do
    key = send_mode_key(attrs)

    with {:ok, levels} <- Store.in_scope(scope, fn _status -> Store.send_modes() end) do
      current = Enum.find_value(levels, &(&1["key"] == key && &1["mode"]))
      {:ok, Authz.send_mode_relaxes?(current, attrs.mode)}
    end
  end

  @doc "The settings key of a send mode level."
  @spec send_mode_key(map()) :: String.t()
  def send_mode_key(%{category: category, channel: channel}) when is_binary(category),
    do: "send_mode.category." <> category <> ".channel." <> channel

  def send_mode_key(%{channel: channel}) when is_binary(channel),
    do: "send_mode.channel." <> channel

  def send_mode_key(_attrs), do: "send_mode"

  # OP-51
  @doc "Sets or clears one send mode level of `scope`; audited as `send_mode.changed`."
  @spec set_send_mode(Scope.t(), map(), Actor.t(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, Relay.Error.t()}
  def set_send_mode(%Scope{} = scope, attrs, %Actor{} = actor, step_up_ref) do
    key = send_mode_key(attrs)

    digest =
      Operators.record_digest(
        scope,
        "send_mode.changed",
        actor,
        "setting",
        key,
        attrs.mode || "cleared"
      )

    Store.in_scope(scope, fn _status ->
      case Store.send_mode_set(Map.put(attrs, :step_up_ref, step_up_ref), digest, actor) do
        {:invalid_level, _previous, _relaxed} ->
          {:error, field("/category", "not_allowed", "category needs channel")}

        {_result, _previous, _relaxed} ->
          {:ok, Enum.find(Store.send_modes(), &(&1["key"] == key))}
      end
    end)
    |> unwrap()
  end

  # API-52
  @doc "Reads the API version pin of the tenant of `scope`."
  @spec api_version(Scope.t()) :: {:ok, map()} | {:error, term()}
  def api_version(%Scope{} = scope),
    do: Store.in_scope(scope, fn _status -> Store.api_version() end)

  # API-52
  @doc "Moves the API version pin of the tenant of `scope`; audited as `api_version.pinned`."
  @spec set_api_version(Scope.t(), String.t(), Actor.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def set_api_version(%Scope{} = scope, version, %Actor{} = actor) do
    target = Relay.Id.to_string(scope.tenant_id)
    digest = Operators.record_digest(scope, "api_version.pinned", actor, "tenant", target, nil)

    Store.in_scope(scope, fn _status ->
      case Store.api_version_set(version, digest, actor) do
        :unsupported -> {:error, field("/version", "unsupported_value", "unsupported version")}
        _pinned -> {:ok, Store.api_version()}
      end
    end)
    |> unwrap()
  end

  defp digest(scope, action, actor, target_type, target, %{reason: reason}),
    do: Operators.record_digest(scope, action, actor, target_type, target, reason)

  defp digest(scope, action, actor, target_type, target, reason),
    do: Operators.record_digest(scope, action, actor, target_type, target, reason)

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, {:error, error}}), do: {:error, error}
  defp unwrap({:error, %Relay.Error{} = error}), do: {:error, error}

  defp conflict(detail), do: Relay.Error.new(:resource_conflict, detail)
  defp operator_not_found, do: Relay.Error.new(:operator_not_found, "no such operator")

  defp field(pointer, code, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end
end
