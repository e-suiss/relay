defmodule Relay.Agents do
  @moduledoc """
  Waitpoints, agent mailboxes and agent protocols. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Agents.Correlation
  alias Relay.Agents.Mailbox
  alias Relay.Agents.Waitpoint
  alias Relay.Agents.WakeHint

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

  # AG-53
  # AG-70
  @doc "The published limits of the agent face of a mailbox; see `Relay.Agents.Mailbox.limits/0`."
  @spec mailbox_limits() :: map()
  defdelegate mailbox_limits(), to: Mailbox, as: :limits

  # AG-20
  # AG-64
  @doc "Opens the mailbox of an agent or an API client if it has none and reads it; see `Relay.Agents.Mailbox.open/2`."
  @spec mailbox(Relay.Scope.t(), Mailbox.owner()) :: {:ok, Mailbox.view()} | {:error, term()}
  defdelegate mailbox(scope, owner), to: Mailbox, as: :open

  # AG-20
  # AG-22
  @doc "Leases mailbox records in a transaction of its own; see `Relay.Agents.Mailbox.lease/3`."
  @spec lease_mailbox(Relay.Scope.t(), Mailbox.owner(), pos_integer()) ::
          {:ok, Mailbox.lease()} | {:error, term()}
  defdelegate lease_mailbox(scope, owner, max), to: Mailbox, as: :lease

  # AG-20
  # AG-22
  @doc "Leases mailbox records inside the caller's scoped transaction; see `Relay.Agents.Mailbox.lease_in/2`."
  @spec lease_mailbox_in(Mailbox.owner(), pos_integer()) ::
          {:ok, Mailbox.lease()} | {:error, atom()}
  defdelegate lease_mailbox_in(owner, max), to: Mailbox, as: :lease_in

  # AG-20
  @doc "Acknowledges the records of a lease in a transaction of its own; see `Relay.Agents.Mailbox.ack/4`."
  @spec ack_mailbox(Relay.Scope.t(), Mailbox.owner(), String.t(), [Relay.Id.t()]) ::
          {:ok, map()} | {:error, term()}
  defdelegate ack_mailbox(scope, owner, lease_id, record_ids), to: Mailbox, as: :ack

  # AG-20
  @doc "Acknowledges the records of a lease inside the caller's scoped transaction; see `Relay.Agents.Mailbox.ack_in/3`."
  @spec ack_mailbox_in(Mailbox.owner(), String.t(), [Relay.Id.t()]) ::
          {:ok, map()} | {:error, atom()}
  defdelegate ack_mailbox_in(owner, lease_id, record_ids), to: Mailbox, as: :ack_in

  # AG-24
  @doc "Reads mailbox records after a position in sequence order; see `Relay.Agents.Mailbox.read/4`."
  @spec read_mailbox(Relay.Scope.t(), Mailbox.owner(), Mailbox.position() | nil, pos_integer()) ::
          {:ok, Mailbox.page()} | {:resync_required, Mailbox.position()} | {:error, term()}
  defdelegate read_mailbox(scope, owner, since, limit), to: Mailbox, as: :read

  # AG-21
  @doc "Reads a mailbox record by its durable handle; see `Relay.Agents.Mailbox.record/3`."
  @spec mailbox_record(Relay.Scope.t(), Relay.Id.t(), Mailbox.owner() | :any) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate mailbox_record(scope, record_id, whose), to: Mailbox, as: :record

  # AG-22
  @doc "A page of the dead-lettered records of a mailbox; see `Relay.Agents.Mailbox.dead_letters/4`."
  @spec mailbox_dead_letters(
          Relay.Scope.t(),
          Mailbox.owner() | {:id, Relay.Id.t()},
          map() | nil,
          pos_integer()
        ) :: {:ok, [map()]} | {:error, term()}
  defdelegate mailbox_dead_letters(scope, whose, cursor, limit), to: Mailbox, as: :dead_letters

  # AG-21
  @doc "The jobs the configured wake transports derive from an outbox event; see `Relay.Agents.WakeHint.jobs/1`."
  @spec wake_jobs(map()) :: [Ecto.Changeset.t()]
  defdelegate wake_jobs(event), to: WakeHint, as: :jobs

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
