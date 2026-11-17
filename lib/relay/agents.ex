defmodule Relay.Agents do
  @moduledoc """
  Waitpoints with their escalation chain and surface policy, agent mailboxes and agent protocols. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Agents.Correlation
  alias Relay.Agents.Escalation
  alias Relay.Agents.Waitpoint

  # AG-65
  @doc "The digests of an event type and a correlation key under every readable lookup key; see `Relay.Agents.Correlation.digests/3`."
  @spec correlation_digests(Relay.Scope.t(), String.t(), String.t()) ::
          {:ok, [Correlation.digest(), ...]} | {:error, Relay.Error.t()}
  defdelegate correlation_digests(scope, event_type, key), to: Correlation, as: :digests

  # AG-65
  @doc "The digests of several pairs of event type and correlation key; see `Relay.Agents.Correlation.digest_map/2`."
  @spec correlation_digest_map(Relay.Scope.t(), [Correlation.pair()]) ::
          {:ok, %{Correlation.pair() => [Correlation.digest(), ...]}} | {:error, Relay.Error.t()}
  defdelegate correlation_digest_map(scope, pairs), to: Correlation, as: :digest_map

  # AG-65
  @doc "Converts a batch of rows of a scope that still hold a correlation key in clear; see `Relay.Agents.Correlation.backfill/2`."
  @spec backfill_correlation_digests(Relay.Scope.t(), pos_integer()) ::
          {:ok, %{scanned: non_neg_integer(), updated: non_neg_integer()}} | {:error, term()}
  defdelegate backfill_correlation_digests(scope, limit), to: Correlation, as: :backfill

  # C-72
  # AG-9
  @doc "Opens a waitpoint; see `Relay.Agents.Waitpoint.open/3`."
  @spec open_waitpoint(Relay.Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate open_waitpoint(scope, attrs, opts \\ []), to: Waitpoint, as: :open

  # AG-14
  @doc "Offers an event to the waitpoints that wait for it; see `Relay.Agents.Waitpoint.offer_event/2`."
  @spec offer_event(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate offer_event(scope, event), to: Waitpoint

  # WF-12
  @doc "Opens a waitpoint inside the caller's scoped transaction; see `Relay.Agents.Waitpoint.open_in/3`."
  @spec open_waitpoint_in(Relay.Scope.t(), map(), keyword()) :: map()
  defdelegate open_waitpoint_in(scope, attrs, opts \\ []), to: Waitpoint, as: :open_in

  # WF-12
  @doc "Offers an event inside the caller's scoped transaction with a second-stage decision; see `Relay.Agents.Waitpoint.offer_in/3`."
  @spec offer_event_in(Relay.Scope.t(), map(), (map() -> boolean())) :: map()
  defdelegate offer_event_in(scope, event, accept), to: Waitpoint, as: :offer_in

  # AG-11
  @doc "Answers a waitpoint once; see `Relay.Agents.Waitpoint.respond/3`."
  @spec respond(Relay.Scope.t(), Relay.Id.t(), map()) :: {:ok, tuple()} | {:error, term()}
  defdelegate respond(scope, waitpoint_id, response), to: Waitpoint

  # WH-68
  @doc "Completes an event waitpoint by its identifier; see `Relay.Agents.Waitpoint.complete/3`."
  @spec complete_waitpoint(Relay.Scope.t(), Relay.Id.t(), Waitpoint.completion() | nil) ::
          {:ok, :resolved | :expired | :already_terminal | :not_found | :not_completable}
          | {:error, term()}
  defdelegate complete_waitpoint(scope, waitpoint_id, completion \\ nil),
    to: Waitpoint,
    as: :complete

  # WH-68
  @doc "Reads the completion that resolved a waitpoint, its result still sealed, or `nil`; see `Relay.Agents.Waitpoint.completion/2`."
  @spec waitpoint_completion(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate waitpoint_completion(scope, waitpoint_id), to: Waitpoint, as: :completion

  # AG-15
  @doc "Renews a waiter's heartbeat; see `Relay.Agents.Waitpoint.heartbeat/4`."
  @spec heartbeat(Relay.Scope.t(), Relay.Id.t(), Waitpoint.waiter_kind(), Relay.Id.t()) ::
          {:ok, tuple()} | {:error, term()}
  defdelegate heartbeat(scope, waitpoint_id, waiter_kind, waiter_ref), to: Waitpoint

  # C-72
  @doc "Cancels a waitpoint; see `Relay.Agents.Waitpoint.cancel/5`."
  @spec cancel_waitpoint(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, atom()} | {:error, term()}
  defdelegate cancel_waitpoint(scope, waitpoint_id, reason, record_digest, actor),
    to: Waitpoint,
    as: :cancel

  @doc "Reads a waitpoint."
  @spec get_waitpoint(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  defdelegate get_waitpoint(scope, waitpoint_id), to: Waitpoint, as: :get

  # AG-46
  @doc "Lists waitpoints; see `Relay.Agents.Waitpoint.list/2`."
  @spec list_waitpoints(Relay.Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_waitpoints(scope, filter), to: Waitpoint, as: :list

  # T-24
  # TN-8
  @doc "Fires the waitpoints of a scope whose timers are due; the virtual clock tick calls it after a step."
  @spec run_due(Relay.Scope.t()) :: :ok | {:error, term()}
  defdelegate run_due(scope), to: Waitpoint

  # AG-53
  @doc "The escalation tier limit; see `Relay.Agents.Escalation.tier_limit/0`."
  @spec escalation_tier_limit() :: %{limit: pos_integer(), path: [String.t(), ...]}
  defdelegate escalation_tier_limit(), to: Escalation, as: :tier_limit

  # AG-17
  @doc "Writes an escalation policy version inside the caller's scoped transaction; see `Relay.Agents.Escalation.put_policy/5`."
  @spec put_escalation_policy(String.t(), map(), integer() | nil, binary(), Relay.Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  defdelegate put_escalation_policy(key, attrs, expected_version, digest, actor),
    to: Escalation,
    as: :put_policy

  # AG-17
  @doc "Archives an escalation policy inside the caller's scoped transaction; see `Relay.Agents.Escalation.archive_policy/3`."
  @spec archive_escalation_policy(String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:archived | :already_archived | :not_found, pos_integer() | nil}
  defdelegate archive_escalation_policy(key, digest, actor), to: Escalation, as: :archive_policy

  # AG-17
  @doc "Reads an escalation policy with its latest version inside the caller's scoped transaction, or `nil`."
  @spec escalation_policy(String.t()) :: map() | nil
  defdelegate escalation_policy(key), to: Escalation, as: :policy

  # AG-17
  @doc "Reads an escalation policy with its latest version; see `Relay.Agents.Escalation.get_policy/2`."
  @spec get_escalation_policy(Relay.Scope.t(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate get_escalation_policy(scope, key), to: Escalation, as: :get_policy

  # AG-17
  # API-56
  @doc "Lists escalation policies; see `Relay.Agents.Escalation.list_policies/4`."
  @spec list_escalation_policies(Relay.Scope.t(), String.t() | nil, map() | nil, integer()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate list_escalation_policies(scope, state, cursor, limit),
    to: Escalation,
    as: :list_policies

  # AG-17
  # API-56
  @doc "Lists the versions of an escalation policy; see `Relay.Agents.Escalation.policy_versions/4`."
  @spec escalation_policy_versions(Relay.Scope.t(), String.t(), map() | nil, pos_integer()) ::
          {:ok, [map()] | nil} | {:error, term()}
  defdelegate escalation_policy_versions(scope, key, cursor, limit),
    to: Escalation,
    as: :policy_versions

  # AG-17
  @doc "The recipients among `ids` that exist and are not deleted; see `Relay.Agents.Escalation.known_recipients/2`."
  @spec known_recipients(Relay.Scope.t(), [Relay.Id.t()]) ::
          {:ok, [{Relay.Id.t(), String.t()}]} | {:error, term()}
  defdelegate known_recipients(scope, ids), to: Escalation

  # AG-63
  # INV-35
  @doc "Settles an invitation of a waitpoint; see `Relay.Agents.Escalation.settle/3`."
  @spec settle_invitation(Relay.Scope.t(), Relay.Id.t(), :delivered | :unreachable) ::
          {:ok, {atom(), DateTime.t() | nil}} | {:error, term()}
  defdelegate settle_invitation(scope, invitation_id, outcome), to: Escalation, as: :settle

  # AG-19
  @doc "The escalation tiers and surface steps of a waitpoint; see `Relay.Agents.Escalation.steps/2`."
  @spec waitpoint_steps(Relay.Scope.t(), Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate waitpoint_steps(scope, waitpoint_id), to: Escalation, as: :steps

  # AG-63
  @doc "The invitations of a waitpoint; see `Relay.Agents.Escalation.invitations/2`."
  @spec waitpoint_invitations(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate waitpoint_invitations(scope, waitpoint_id), to: Escalation, as: :invitations
end
