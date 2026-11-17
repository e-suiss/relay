defmodule Relay.Agents do
  @moduledoc """
  Agent recipient records, waitpoints with their escalation chain and surface policy, agent mailboxes and agent protocols. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.AgentProtocols, as: Protocols
  alias Relay.Agents.A2a
  alias Relay.Agents.Correlation
  alias Relay.Agents.Escalation
  alias Relay.Agents.FirstContact
  alias Relay.Agents.Mailbox
  alias Relay.Agents.Registry
  alias Relay.Agents.ResponseToken
  alias Relay.Agents.TaskNotifications
  alias Relay.Agents.Waitpoint
  alias Relay.Agents.WakeHint

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

  # AG-53
  # AG-70
  @doc "The published limits of messages between agents; see `Relay.Agents.FirstContact.limits/0`."
  @spec message_limits() :: map()
  defdelegate message_limits(), to: FirstContact, as: :limits

  # AG-58
  # AG-74
  @doc "Whether an installation of a region carries encrypted envelopes; see `Relay.Agents.FirstContact.transport/2`."
  @spec encrypted_transport(String.t() | atom(), map() | nil) :: :enabled | :disabled
  defdelegate encrypted_transport(region, content), to: FirstContact, as: :transport

  # AG-60
  # AG-73
  @doc "Reads a first-contact token against the issuer; see `Relay.Agents.FirstContact.token/2`."
  @spec first_contact_token(binary() | nil, map() | nil) :: FirstContact.token()
  defdelegate first_contact_token(token, issuer), to: FirstContact, as: :token

  # AG-60
  # AG-73
  @doc "The challenge a first-contact token answers; see `Relay.Agents.FirstContact.challenge/2`."
  @spec first_contact_challenge(String.t(), String.t()) :: binary()
  defdelegate first_contact_challenge(issuer_name, origin), to: FirstContact, as: :challenge

  # AG-56
  # AG-59
  # AG-60
  # AG-61
  @doc "Sends a message to an agent's mailbox inside the caller's scoped transaction; see `Relay.Agents.FirstContact.send_in/1`."
  @spec send_message_in(FirstContact.message()) ::
          {:ok, map()} | {:error, atom() | {:rate_limited, map()}}
  defdelegate send_message_in(message), to: FirstContact, as: :send_in

  # AG-59
  # AG-61
  # AG-69
  @doc "How a sender stands with a recipient: relationship level, block and first-contact rate; see `Relay.Agents.FirstContact.standing/3`."
  @spec sender_standing(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, FirstContact.standing()} | {:error, term()}
  defdelegate sender_standing(scope, recipient_id, sender_id), to: FirstContact, as: :standing

  # AG-69
  @doc "How a sender stands with a recipient, inside the caller's scoped transaction; see `Relay.Agents.FirstContact.standing_in/2`."
  @spec sender_standing_in(Relay.Id.t(), Relay.Id.t()) :: FirstContact.standing()
  defdelegate sender_standing_in(recipient_id, sender_id), to: FirstContact, as: :standing_in

  # AG-38
  # AG-69
  @doc "The trust label of a message by the order of AG-69; see `Relay.Agents.FirstContact.trust_label/1`."
  @spec trust_label(map()) :: FirstContact.label()
  defdelegate trust_label(facts), to: FirstContact

  # AG-59
  # AG-73
  @doc "Applies a relationship level from Access to the copy of a scope; see `Relay.Agents.FirstContact.relationship_changed/2`."
  @spec relationship_changed(Relay.Scope.t(), map()) ::
          {:ok, :applied | :stale | :agent_not_found} | {:error, term()}
  defdelegate relationship_changed(scope, relationship), to: FirstContact

  # AG-61
  @doc "Blocks a sender for an agent or lifts the block inside the caller's scoped transaction; see `Relay.Agents.FirstContact.set_block_in/4`."
  @spec set_sender_block_in(Relay.Id.t(), Relay.Id.t(), boolean(), String.t()) ::
          {:blocked | :lifted | :unchanged, map()} | {:sender_not_found, nil}
  defdelegate set_sender_block_in(owner_id, sender_id, blocked, actor_ref),
    to: FirstContact,
    as: :set_block_in

  # AG-61
  @doc "Reports a message as abuse inside the caller's scoped transaction; see `Relay.Agents.FirstContact.report_abuse_in/4`."
  @spec report_abuse_in(Relay.Id.t(), Relay.Id.t(), String.t(), String.t() | nil) ::
          {:reported | :already_reported | :not_found, DateTime.t() | nil, boolean() | nil}
  defdelegate report_abuse_in(reporter_id, record_id, sender_ref, statement), to: FirstContact

  # AG-67
  @doc "Reads the metadata of a message of a recipient inside the caller's scoped transaction, or `nil`."
  @spec message_in(Relay.Id.t(), Relay.Id.t()) :: map() | nil
  defdelegate message_in(recipient_id, record_id), to: FirstContact

  # AG-56
  # AG-67
  @doc "Reads a message of a recipient with its stored envelope; see `Relay.Agents.FirstContact.envelope/3`."
  @spec message_envelope(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate message_envelope(scope, recipient_id, record_id), to: FirstContact, as: :envelope

  # AG-59
  # API-56
  @doc "A page of the request box of a recipient; see `Relay.Agents.FirstContact.requests/4`."
  @spec mailbox_requests(Relay.Scope.t(), Relay.Id.t(), map() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate mailbox_requests(scope, recipient_id, cursor, limit),
    to: FirstContact,
    as: :requests

  # AG-21
  # AG-35
  @doc "The jobs derived from an outbox event inside the dispatch transaction: those of the configured wake transports for the event of a mailbox record (`Relay.Agents.WakeHint.jobs/1`) and those of the invitation sink for the event of a closed waitpoint (`Relay.Agents.Escalation.closed_jobs/1`)."
  @spec wake_jobs(map()) :: [Ecto.Changeset.t()]
  def wake_jobs(event), do: WakeHint.jobs(event) ++ Escalation.closed_jobs(event)

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

  # AG-46
  # L-28
  @doc "What a protocol (`:a2a`, `:mcp_tasks` or `:managed_agents`) sees of a waitpoint; see `Relay.AgentProtocols.of/3`."
  @spec protocol_state(Protocols.protocol(), map()) :: {:ok, Protocols.cell()} | :error
  def protocol_state(protocol, waitpoint),
    do: Protocols.of(Protocols.bundled(), protocol, waitpoint)

  # AG-46
  @doc "Every waitpoint state and interaction a protocol state stands for; see `Relay.AgentProtocols.waitpoints/3`."
  @spec protocol_waitpoints(Protocols.protocol(), String.t()) :: [{String.t(), String.t()}]
  def protocol_waitpoints(protocol, protocol_state),
    do: Protocols.waitpoints(Protocols.bundled(), protocol, protocol_state)

  # E-50
  # AG-47
  @doc "The version of `a2a` or `mcp` Relay speaks when it sends."
  @spec protocol_version(String.t()) :: String.t()
  def protocol_version(protocol), do: Protocols.current(Protocols.bundled(), protocol)

  # AG-72
  @doc "The versions of `a2a` or `mcp` Relay serves."
  @spec protocol_versions(String.t()) :: [String.t(), ...]
  def protocol_versions(protocol), do: Protocols.served(Protocols.bundled(), protocol)

  # AG-42
  # AG-21
  @doc "The A2A push notification of a mailbox record inside the caller's scoped transaction, or `nil`; see `Relay.Agents.A2a.push_in/2`."
  @spec a2a_push_in(Relay.Id.t(), Relay.Id.t()) :: A2a.push() | nil
  defdelegate a2a_push_in(mailbox_id, record_id), to: A2a, as: :push_in

  # AG-42
  # AG-37
  @doc "Reads an A2A `StreamResponse` as a task notification; see `Relay.Agents.A2a.notification/1`."
  @spec a2a_notification(term()) :: {:ok, A2a.notification()} | :error
  defdelegate a2a_notification(body), to: A2a, as: :notification

  # AG-42
  # INV-35
  @doc "Reads the answer of A2A `GetTask`; see `Relay.Agents.A2a.task/1`."
  @spec a2a_task(term()) :: {:ok, A2a.notification()} | :error
  defdelegate a2a_task(body), to: A2a, as: :task

  # AG-42
  @doc "Checks the `A2A-Version` values of a request; see `Relay.Agents.A2a.version/1`."
  @spec a2a_version([String.t()]) :: {:ok, String.t()} | {:error, :version_not_supported}
  defdelegate a2a_version(values), to: A2a, as: :version

  # AG-37
  # INV-35
  @doc "Applies a task notification of a registered source; see `Relay.Agents.TaskNotifications.record/2`."
  @spec record_task_notification(Relay.Scope.t(), TaskNotifications.attrs()) ::
          {:ok, TaskNotifications.result()} | {:error, term()}
  defdelegate record_task_notification(scope, attrs), to: TaskNotifications, as: :record

  # AG-37
  @doc "Reads the recorded state of a task of a source, or `nil`; see `Relay.Agents.TaskNotifications.get/3`."
  @spec task_notification(Relay.Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate task_notification(scope, source_id, task), to: TaskNotifications, as: :get

  # AG-42
  # INV-35
  @doc "Reads a task again at its source and applies what it reports; see `Relay.Agents.TaskNotifications.reconcile/3`."
  @spec reconcile_task(Relay.Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, TaskNotifications.result() | :unconfigured | :unreadable} | {:error, term()}
  defdelegate reconcile_task(scope, source_id, task), to: TaskNotifications, as: :reconcile

  # AG-63
  @doc "Reads an invitation with the kind of its responder inside the caller's scoped transaction, or `nil`; see `Relay.Agents.Escalation.invitation/1`."
  @spec invitation(Relay.Id.t()) :: map() | nil
  defdelegate invitation(invitation_id), to: Escalation

  # INV-33
  # AG-30
  # AG-31
  @doc "Mints the response token of a responder for a waitpoint; see `Relay.Agents.ResponseToken.mint/3`."
  @spec mint_response_token(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, ResponseToken.token()} | {:error, atom()}
  defdelegate mint_response_token(scope, waitpoint_id, recipient_id),
    to: ResponseToken,
    as: :mint
end
