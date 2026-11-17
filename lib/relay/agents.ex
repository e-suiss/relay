defmodule Relay.Agents do
  @moduledoc """
  Agent recipient records, waitpoints, agent mailboxes and agent protocols. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Agents.Correlation
  alias Relay.Agents.Registry
  alias Relay.Agents.Waitpoint

  # C-21
  # E-29
  @doc "Prepares the creation of an agent recipient outside any transaction; see `Relay.Agents.Registry.prepare/2`."
  @spec prepare_agent(Relay.Scope.t(), Registry.input()) ::
          {:ok, Registry.plan()} | {:error, Relay.Error.t()}
  defdelegate prepare_agent(scope, input), to: Registry, as: :prepare

  # C-21
  # E-28
  # C-68
  @doc "Creates a prepared agent recipient inside the caller's scoped transaction; see `Relay.Agents.Registry.create/3`."
  @spec create_agent(Registry.plan(), <<_::256>>, Relay.Actor.t()) ::
          {:created, Registry.agent()} | {atom(), nil}
  defdelegate create_agent(plan, digest, actor), to: Registry, as: :create

  # C-21
  # E-28
  @doc "Changes an agent recipient inside the caller's scoped transaction; see `Relay.Agents.Registry.update/5`."
  @spec update_agent(Relay.Id.t(), map(), pos_integer() | nil, binary(), Relay.Actor.t()) ::
          {:updated, map()} | {atom(), pos_integer() | nil}
  defdelegate update_agent(id, change, expected_version, digest, actor),
    to: Registry,
    as: :update

  # AG-5
  # AG-23
  # INV-47
  @doc "Soft-deletes an agent recipient inside the caller's scoped transaction, keeping its mailbox; see `Relay.Agents.Registry.delete/3`."
  @spec delete_agent(Relay.Id.t(), <<_::256>>, Relay.Actor.t()) ::
          {:deleted | :unchanged, Registry.agent()} | {:not_found, nil}
  defdelegate delete_agent(id, digest, actor), to: Registry, as: :delete

  # C-21
  # E-28
  @doc "Reads an agent recipient, or `nil`; see `Relay.Agents.Registry.get/2`."
  @spec get_agent(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, Registry.agent() | nil} | {:error, term()}
  defdelegate get_agent(scope, id), to: Registry, as: :get

  # C-21
  # API-56
  @doc "Lists agent recipients; see `Relay.Agents.Registry.list/3`."
  @spec list_agents(Relay.Scope.t(), map() | nil, pos_integer()) ::
          {:ok, [Registry.agent()]} | {:error, term()}
  defdelegate list_agents(scope, cursor, limit), to: Registry, as: :list

  # E-29
  # AG-5
  # TN-25
  @doc "The agent bound to the Access Party `subject` of a verified token, with its state, or `nil`; see `Relay.Agents.Registry.credential/2`."
  @spec agent_credential(Relay.Scope.t(), String.t() | nil) ::
          {:ok, %{id: Relay.Id.t(), state: String.t()} | nil} | {:error, term()}
  defdelegate agent_credential(scope, subject), to: Registry, as: :credential

  # AG-5
  # E-29
  @doc "The state of an agent recipient, or `nil`; see `Relay.Agents.Registry.state/2`. Whoever delivers to an agent or serves it reads this first: only an `active` agent is delivered to."
  @spec agent_state(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t() | nil} | {:error, term()}
  defdelegate agent_state(scope, id), to: Registry, as: :state

  # E-29
  # AG-5
  # INV-47
  @doc "Reflects an Access agent lifecycle event on the agent of a scope bound to an Access Party; see `Relay.Agents.Registry.access_changed/4`."
  @spec agent_access_changed(
          Relay.Scope.t(),
          :suspended | :reactivated | :deleted,
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  defdelegate agent_access_changed(scope, kind, subject, event_ref),
    to: Registry,
    as: :access_changed

  # TN-48
  @doc "A record digest over an action, the scope and a reference; see `Relay.Agents.Registry.digest/3`."
  @spec agent_digest(Relay.Scope.t(), String.t(), String.t()) :: <<_::256>>
  defdelegate agent_digest(scope, action, ref), to: Registry, as: :digest

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

  # AG-46
  # API-56
  @doc "A page of the waitpoints of agents and API clients, newest first; see `Relay.Agents.Waitpoint.page/4`."
  @spec page_waitpoints(Relay.Scope.t(), map(), map() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate page_waitpoints(scope, filter, cursor, limit), to: Waitpoint, as: :page

  # AG-12
  # AG-25
  @doc "Reads a waitpoint with its responders and its response, or `nil`; see `Relay.Agents.Waitpoint.read/2`."
  @spec read_waitpoint(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  defdelegate read_waitpoint(scope, waitpoint_id), to: Waitpoint, as: :read

  # AG-12
  # AG-25
  @doc "Reads a waitpoint with its responders and its response inside the caller's scoped transaction; see `Relay.Agents.Waitpoint.read_in/1`."
  @spec read_waitpoint_in(Relay.Id.t()) :: map() | nil
  defdelegate read_waitpoint_in(waitpoint_id), to: Waitpoint, as: :read_in

  # AG-12
  # AG-25
  @doc "Adds responders and responses to waitpoints; see `Relay.Agents.Waitpoint.details/2`."
  @spec waitpoint_details(Relay.Scope.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  defdelegate waitpoint_details(scope, waitpoints), to: Waitpoint, as: :details

  # C-72
  # AG-46
  @doc "Cancels a waitpoint inside the caller's scoped transaction; see `Relay.Agents.Waitpoint.cancel_in/4`."
  @spec cancel_waitpoint_in(Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          :cancelled | :already_terminal | :not_found
  defdelegate cancel_waitpoint_in(waitpoint_id, reason, record_digest, actor),
    to: Waitpoint,
    as: :cancel_in

  # AG-10
  # AG-15
  @doc "Renews a waiter's heartbeat inside the caller's scoped transaction; see `Relay.Agents.Waitpoint.heartbeat_in/3`."
  @spec heartbeat_in(Relay.Id.t(), Waitpoint.waiter_kind(), Relay.Id.t()) ::
          {atom(), DateTime.t() | nil}
  defdelegate heartbeat_in(waitpoint_id, waiter_kind, waiter_ref), to: Waitpoint

  # AG-53
  # TN-54
  @doc "The number of open and stalled waitpoints of the scope and the contract's limits on it, inside the caller's scoped transaction."
  @spec open_waitpoints_in() :: %{required(:open | :tenant | :waiter) => non_neg_integer()}
  def open_waitpoints_in, do: Map.put(Waitpoint.default_caps(), :open, Waitpoint.open_count_in())

  # T-24
  # TN-8
  @doc "Fires the waitpoints of a scope whose timers are due; the virtual clock tick calls it after a step."
  @spec run_due(Relay.Scope.t()) :: :ok | {:error, term()}
  defdelegate run_due(scope), to: Waitpoint
end
