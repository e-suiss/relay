defmodule Relay.Agents.Escalation do
  @moduledoc """
  The escalation chain and the sender's surface policy of a waitpoint (AG-17, AG-18, AG-19, AG-63, WF-24, WF-25). An escalation policy is a named, versioned definition of tiers its owner writes; Relay applies it and decides nothing: a tier invites responders of the waitpoint's own set, on more channels or again, and after the last tier nothing happens until the deadline, which produces only `waitpoint.expired` (AG-18). A waitpoint pins one policy version, or an inline definition of its own, when it is opened.

  Tiers and surface steps are rows of one table that the waitpoint's one timer runs (`Relay.Agents.WaitpointTimer`, WF-43): the nearest armed step is the waitpoint's escalation time. A step fires only on an open waitpoint before its deadline; a resolved, expired or cancelled waitpoint cancels its pending steps and the invitations not yet delivered, a stalled one suspends its armed step with the time it had left and a returning heartbeat arms it again (AG-10, AG-19). These rules are triggers and constraints of the database, so no caller can skip them. Relay cancels only these steps and invitations of its own; it compensates nothing (INV-35, AG-3).

  An invitation is the durable request to invite one responder on a set of surfaces. Every responder an invitation names is in the waitpoint's responders by foreign key (AG-12). After a pin, a fired step or a settled invitation, the invitations still requested are announced inside the same transaction to the configured sink (`config :relay, Relay.Agents, invitation_sink: Module`: `Module.waitpoint_invitations(scope, waitpoint_id, invitations)`); without a sink they stay requested. The delivery side settles each one with `settle/3`. When the waitpoint is resolved, expired or cancelled, the sink derives its closing jobs from the waitpoint's outbox event (`Module.waitpoint_closed_jobs(scope, waitpoint_id)`, AG-35).
  """

  alias Relay.Actor
  alias Relay.Agents.EscalationStore

  @limit ["waitpoint", "max_escalation_tiers"]
  @max_tiers Relay.Limits.fetch!(@limit)
  @closing ["waitpoint.resolved", "waitpoint.expired", "waitpoint.cancelled"]

  @typedoc "What a waitpoint asks for when it is opened: a stored policy by `:key` and optional `:version`, or inline `:tiers`."
  @type escalation :: %{
          optional(:key) => String.t(),
          optional(:version) => pos_integer() | nil,
          optional(:tiers) => [map()]
        }

  # AG-53
  @doc "The most escalation tiers a waitpoint or a policy version has, and the path of that limit in the contract's limits."
  @spec tier_limit() :: %{limit: pos_integer(), path: [String.t(), ...]}
  def tier_limit, do: %{limit: @max_tiers, path: @limit}

  # AG-17
  # AG-53
  @doc "Writes a version of the escalation policy `key` inside the caller's scoped transaction. `attrs` carries the `:tiers` in their stored form (`after_ms`, `add_responders` as maps of `kind` and `id`, the recipient identifier, `channels`, `repeat`, `skip_if_empty`) and an optional `:description`. The first version creates the policy; a later one needs the latest version as `expected_version`."
  @spec put_policy(String.t(), map(), pos_integer() | nil, <<_::256>>, Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def put_policy(key, attrs, expected_version, digest, %Actor{} = actor) do
    row = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: key,
      description: Map.get(attrs, :description),
      tiers: attrs.tiers
    }

    EscalationStore.put(row, expected_version, @max_tiers, digest, actor)
  end

  # AG-17
  @doc "Archives an escalation policy inside the caller's scoped transaction; a waitpoint that pinned a version keeps it."
  @spec archive_policy(String.t(), <<_::256>>, Actor.t()) ::
          {:archived | :already_archived | :not_found, pos_integer() | nil}
  defdelegate archive_policy(key, digest, actor), to: EscalationStore, as: :archive

  # AG-17
  @doc "Reads an escalation policy with its latest version inside the caller's scoped transaction, or `nil`."
  @spec policy(String.t()) :: map() | nil
  defdelegate policy(key), to: EscalationStore, as: :get

  # AG-17
  @doc "Reads an escalation policy with its latest version in its own read transaction."
  @spec get_policy(Relay.Scope.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_policy(%Relay.Scope{} = scope, key),
    do: EscalationStore.in_scope(scope, fn _status -> EscalationStore.get(key) end)

  # AG-17
  # X-10
  @doc "Where an escalation policy is used, in its own read transaction: `nil` for an unknown key, else its latest version and the open and stalled waitpoints that pinned each version."
  @spec policy_usage(Relay.Scope.t(), String.t()) ::
          {:ok, %{latest_version: pos_integer(), versions: [map()]} | nil} | {:error, term()}
  def policy_usage(%Relay.Scope{} = scope, key) do
    EscalationStore.in_scope(scope, fn _status ->
      case EscalationStore.get(key) do
        nil ->
          nil

        %{"version" => version} ->
          %{latest_version: version, versions: Relay.Agents.WaitpointStore.policy_usage(key)}
      end
    end)
  end

  # AG-17
  # API-56
  @doc "Lists escalation policies newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec list_policies(Relay.Scope.t(), String.t() | nil, map() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_policies(%Relay.Scope{} = scope, state, cursor, limit) do
    EscalationStore.in_scope(scope, fn _status ->
      EscalationStore.list(state, cursor, limit)
    end)
  end

  # AG-17
  # API-56
  @doc "Lists the versions of an escalation policy newest first from a decoded cursor; `nil` for an unknown key."
  @spec policy_versions(Relay.Scope.t(), String.t(), map() | nil, pos_integer()) ::
          {:ok, [map()] | nil} | {:error, term()}
  def policy_versions(%Relay.Scope{} = scope, key, cursor, limit) do
    EscalationStore.in_scope(scope, fn _status ->
      EscalationStore.versions(key, cursor, limit)
    end)
  end

  # AG-17
  @doc "The recipients among `ids` that exist and are not deleted, as `{id, kind}`, read in a transaction of its own."
  @spec known_recipients(Relay.Scope.t(), [Relay.Id.t()]) ::
          {:ok, [{Relay.Id.t(), String.t()}]} | {:error, term()}
  def known_recipients(%Relay.Scope{} = scope, ids),
    do: EscalationStore.in_scope(scope, fn _status -> EscalationStore.known(ids) end)

  # AG-12
  # AG-17
  # AG-63
  @doc "The plan of the waitpoint attributes `attrs`, or `nil` when they carry neither `:escalation` nor `:surface_policy`."
  @spec plan(map()) :: EscalationStore.plan() | nil
  def plan(attrs) do
    escalation = Map.get(attrs, :escalation)
    surface = Map.get(attrs, :surface_policy)

    if escalation == nil and surface == nil do
      nil
    else
      escalation = escalation || %{}

      %{
        policy_key: Map.get(escalation, :key),
        policy_version: Map.get(escalation, :version),
        tiers: Map.get(escalation, :tiers),
        surface_policy: surface
      }
    end
  end

  # AG-12
  # AG-53
  @doc "Checks a plan against the responders a waitpoint is about to be opened with, inside the caller's scoped transaction: `{:ok, policy_ref}` with the reference the waitpoint stores, or the refusal: `:escalation_policy_not_found`, `:escalation_policy_archived`, `:escalation_responder_outside_set`, `:escalation_tier_limit` or `:surface_recipient_outside_set`."
  @spec check([Relay.Id.t()], EscalationStore.plan()) :: {:ok, String.t() | nil} | atom()
  def check(responder_ids, plan) do
    case EscalationStore.plan_check(responder_ids, plan, @max_tiers) do
      {:ok, ref} -> {:ok, ref}
      {:policy_not_found, _ref} -> :escalation_policy_not_found
      {:policy_archived, _ref} -> :escalation_policy_archived
      {:responder_outside_set, _ref} -> :escalation_responder_outside_set
      {:tier_limit, _ref} -> :escalation_tier_limit
      {:surface_recipient_outside_set, _ref} -> :surface_recipient_outside_set
    end
  end

  # AG-17
  # AG-63
  @doc "Pins a checked plan to the waitpoint just opened and announces its first invitations, inside the caller's scoped transaction."
  @spec pin(Relay.Scope.t(), Relay.Id.t(), EscalationStore.plan()) :: :ok
  def pin(%Relay.Scope{} = scope, waitpoint_id, plan) do
    {:pinned, _next_at} = EscalationStore.plan_pin(waitpoint_id, plan, @max_tiers)
    announce(scope, waitpoint_id)
  end

  # AG-19
  # WF-43
  @doc "Runs the due steps of a waitpoint inside the caller's scoped transaction and announces the invitations they made; returns the time of the next step, or `nil`."
  @spec fire(Relay.Scope.t(), Relay.Id.t()) :: DateTime.t() | nil
  def fire(%Relay.Scope{} = scope, waitpoint_id) do
    case EscalationStore.steps_fire(waitpoint_id) do
      {:fired, _count, next_at} ->
        :ok = announce(scope, waitpoint_id)
        next_at

      {_result, _count, next_at} ->
        next_at
    end
  end

  # AG-63
  # INV-35
  @doc "Settles an invitation in a transaction of its own: `:delivered` once it reached a surface, `:unreachable` when its surfaces are not registered, not permitted or failed for good. An unreachable surface step is recorded as skipped and the next step is invited without waiting; returns the result and the time of the waitpoint's next step."
  @spec settle(Relay.Scope.t(), Relay.Id.t(), :delivered | :unreachable) ::
          {:ok, {atom(), DateTime.t() | nil}} | {:error, term()}
  def settle(%Relay.Scope{} = scope, invitation_id, outcome)
      when outcome in [:delivered, :unreachable] do
    EscalationStore.in_scope(scope, fn _status ->
      settled = EscalationStore.settle(invitation_id, outcome)
      :ok = reannounce(scope, invitation_id, settled, outcome)
      settled
    end)
  end

  # AG-19
  @doc "The steps of a waitpoint, read in a transaction of its own."
  @spec steps(Relay.Scope.t(), Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  def steps(%Relay.Scope{} = scope, waitpoint_id),
    do: EscalationStore.in_scope(scope, fn _status -> EscalationStore.steps(waitpoint_id) end)

  # AG-63
  @doc "The invitations of a waitpoint in every state, read in a transaction of its own."
  @spec invitations(Relay.Scope.t(), Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  def invitations(%Relay.Scope{} = scope, waitpoint_id) do
    states = ["requested", "delivered", "unreachable", "cancelled"]

    EscalationStore.in_scope(scope, fn _status ->
      EscalationStore.invitations(waitpoint_id, states)
    end)
  end

  # AG-63
  @doc "Reads an invitation with the kind of its responder (`recipient_kind`) inside the caller's scoped transaction, or `nil`."
  @spec invitation(Relay.Id.t()) :: map() | nil
  defdelegate invitation(invitation_id), to: EscalationStore

  # AG-28
  # AG-63
  @doc "The plan of a waitpoint that carries neither an escalation nor a surface policy: every responder is invited once, on all its surfaces at the same time."
  @spec direct_plan() :: EscalationStore.plan()
  def direct_plan, do: %{policy_key: nil, policy_version: nil, tiers: nil, surface_policy: nil}

  # AG-35
  # AG-19
  @doc "The jobs the configured invitation sink derives from the outbox event of a waitpoint that was resolved, expired or cancelled, inside the dispatch transaction (`Module.waitpoint_closed_jobs(scope, waitpoint_id)`, the identifier as text); none for any other event or without a sink."
  @spec closed_jobs(map()) :: [Ecto.Changeset.t()]
  def closed_jobs(%{event_type: type, payload: %{"waitpoint_id" => waitpoint_id}})
      when type in @closing and is_binary(waitpoint_id) do
    case {sink(), EscalationStore.current_scope()} do
      {nil, _scope} -> []
      {_sink, nil} -> []
      {sink, scope} -> closing(sink, scope, waitpoint_id)
    end
  end

  def closed_jobs(_event), do: []

  defp closing(sink, scope, waitpoint_id) do
    if Code.ensure_loaded?(sink) and function_exported?(sink, :waitpoint_closed_jobs, 2),
      do: sink.waitpoint_closed_jobs(scope, waitpoint_id),
      else: []
  end

  defp sink, do: Application.get_env(:relay, Relay.Agents, [])[:invitation_sink]

  defp reannounce(scope, invitation_id, {:settled, _next_at}, :unreachable) do
    case EscalationStore.invitation_waitpoint(invitation_id) do
      nil -> :ok
      waitpoint_id -> announce(scope, waitpoint_id)
    end
  end

  defp reannounce(_scope, _invitation_id, _settled, _outcome), do: :ok

  defp announce(scope, waitpoint_id) do
    case sink() do
      nil ->
        :ok

      sink ->
        requested = EscalationStore.invitations(waitpoint_id, ["requested"])
        :ok = sink.waitpoint_invitations(scope, waitpoint_id, requested)
    end
  end
end
