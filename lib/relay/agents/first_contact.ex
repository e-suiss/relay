defmodule Relay.Agents.FirstContact do
  @moduledoc """
  Messages from one agent to the mailbox of another: the end-to-end encrypted envelope, the request box, the first-contact rules, the block list and the abuse report (AG-56 … AG-61, AG-67, AG-69, AG-70, AG-73, AG-74).

  **Encrypted envelope.** A message carries an envelope that is encrypted between the sender and the recipient. Relay holds no key for it, cannot open it, does not render it and passes it through no template; the recipient's keys and mailbox endpoint come from the `did:web` reflection of its Access identity, and Relay is no key directory (AG-56). What Relay sees and records of a message is its metadata and nothing else: the sender, the recipient, the size, the time, the trust label, `relationship` and `content_encryption` (AG-67); no field is derived from the content. The envelope is a mailbox record like any other, sealed at rest under a tenant key before the transaction, so the sequence, the lease, the acknowledgement, the retention and the erasure of the mailbox apply to it, and it is at most the contract's `encrypted_envelope.max_bytes` (AG-57). Its wake-up hint names the record and its position only.

  **Request box.** The relationship level a recipient holds towards a sender (`unknown`, `known`, `verified`, `trusted`) is a copy of Access relationship events, applied under the pair's monotone sequence number: an older or repeated sequence changes nothing (`relationship_changed/2`, AG-73). A level is a policy input and produces no authority. A message of a sender whose level is `unknown` goes to the request box of the mailbox: it is held, never handed out by a lease, resolves no waitpoint, starts no workflow and publishes to no topic, and its only event is `mailbox.request_received`, which wakes only who subscribed to it (AG-59).

  **First contact.** A message to a recipient whose level is `unknown` passes two checks: the sender's first contacts of the last hour and their distinct recipients of the last day stay within the contract's `first_contact` limits, and the message carries a Privacy Pass token that verifies (`Relay.Agents.PrivacyPass`) and was not spent before; its digest is kept for good. Once a level other than `unknown` exists for the pair, neither check applies to it (AG-60).

  **Block.** A recipient blocks a sender. A blocked sender's message passes the same checks as any other and is answered the same, so the sender learns nothing; it is recorded with the label `blocked`, held outside the request box and produces no event, so it wakes nobody (AG-61).

  **Abuse report.** A recipient reports a message once. `mailbox.abuse_reported` goes to the outbox in the same transaction with the metadata of the message (sender, time, size, the sender's rate) and, only when the reporter attaches it, the reporter's own statement marked `reporter_statement_unverified`. Relay decides nothing about abuse (AG-61).

  **Encrypted transport by region.** In an installation of the `eu` region encrypted envelopes are carried only when the active `encrypted_transport` data set turns them on for the region (`transport/2`, AG-74).
  """

  alias Relay.Agents.FirstContactStore, as: Store
  alias Relay.Agents.PrivacyPass
  alias Relay.Agents.Registry
  alias Relay.Scope

  @messages_per_hour Relay.Limits.fetch!(["first_contact", "messages_per_hour"])
  @recipients_per_day Relay.Limits.fetch!(["first_contact", "recipients_per_day"])
  @envelope_bytes Relay.Limits.fetch!(["encrypted_envelope", "max_bytes"])
  @statement_bytes Relay.Limits.fetch!(["encrypted_envelope", "abuse_statement_max_bytes"])
  @levels ~w(unknown known verified trusted)

  @type id :: Relay.Id.t()
  @type level :: :unknown | :known | :verified | :trusted
  @type label :: :blocked | :spam | :authenticated | :unauthenticated
  @type standing :: %{
          relationship: level(),
          blocked: boolean(),
          over_first_contact_rate: boolean()
        }
  @type token :: :none | :invalid | {:valid, PrivacyPass.spent()}
  @typedoc "A message ready to be sent: the sealed envelope and what Relay records of it."
  @type message :: %{
          id: id(),
          recipient_id: id(),
          sender_id: id(),
          content_encryption: String.t(),
          size: pos_integer(),
          payload_ct: binary(),
          payload_tenant_key_id: id(),
          payload_digest: <<_::256>>,
          token: token(),
          traceparent: String.t() | nil
        }

  # AG-53
  # AG-70
  @doc "The limits of messages between agents as the contract publishes them."
  @spec limits() :: %{
          messages_per_hour: pos_integer(),
          recipients_per_day: pos_integer(),
          envelope_max_bytes: pos_integer(),
          statement_max_bytes: pos_integer()
        }
  def limits do
    %{
      messages_per_hour: @messages_per_hour,
      recipients_per_day: @recipients_per_day,
      envelope_max_bytes: @envelope_bytes,
      statement_max_bytes: @statement_bytes
    }
  end

  # AG-58
  # AG-74
  @doc "Whether an installation of `region` carries encrypted envelopes, by the content of the active `encrypted_transport` data set (`nil` without one). Outside the `eu` region they are carried; in it only when the data set turns them on for it."
  @spec transport(String.t() | atom(), map() | nil) :: :enabled | :disabled
  def transport(region, content) when region in ["eu", :eu] do
    regions = if is_map(content), do: Map.get(content, "regions"), else: nil
    listed = if is_list(regions), do: regions, else: []

    if Enum.any?(listed, &match?(%{"region" => "eu", "person_to_person" => true}, &1)),
      do: :enabled,
      else: :disabled
  end

  def transport(_region, _content), do: :enabled

  # AG-60
  # AG-73
  @doc "Reads a first-contact token against the issuer: `:none` without a token, `{:valid, spent}` for one that answers the challenge of the issuer and this origin under one of the issuer's token keys, `:invalid` for anything else, also while no issuer is known."
  @spec token(binary() | nil, map() | nil) :: token()
  def token(nil, _issuer), do: :none

  def token(token, %{issuer_name: issuer_name, origin: origin, token_keys: token_keys})
      when is_binary(token) and is_list(token_keys) do
    keys = for token_key <- token_keys, {:ok, key} <- [PrivacyPass.key(token_key)], do: key
    expected = issuer_name |> PrivacyPass.challenge(origin) |> PrivacyPass.challenge_digest()

    case PrivacyPass.verify(token, expected, keys) do
      {:ok, spent} -> {:valid, spent}
      :error -> :invalid
    end
  end

  def token(_token, _issuer), do: :invalid

  # AG-60
  # AG-73
  @doc "The challenge a first-contact token answers for an issuer and this origin; see `Relay.Agents.PrivacyPass.challenge/2`."
  @spec challenge(String.t(), String.t()) :: binary()
  defdelegate challenge(issuer_name, origin), to: PrivacyPass

  # AG-56
  # AG-57
  # AG-59
  # AG-60
  # AG-61
  @doc """
  Sends a message inside the caller's scoped transaction, with its record, its metadata and its event. Returns `{:ok, sent}` with the record's `:id`, `:box` (`:inbox`, `:requests` or `:blocked`), `:relationship`, `:epoch` and `:seq`, or the refusal:

    * `:self`, `:sender_not_found`, `:recipient_not_found`, `:recipient_inactive`;
    * `:token_required` for a first contact without a token, with one that does not verify or with one spent before;
    * `{:rate_limited, %{limit_name: name, limit: n, actual: n, retry_after: seconds}}` for a first contact over the sender's limits.
  """
  @spec send_in(message()) :: {:ok, map()} | {:error, atom() | {:rate_limited, map()}}
  def send_in(%{token: token} = message) do
    {state, spent} =
      case token do
        {:valid, spent} -> {:valid, spent}
        other when other in [:none, :invalid] -> {other, %{digest: nil, key_id: nil}}
      end

    sent =
      message
      |> Map.merge(%{token: state, token_digest: spent.digest, token_key_id: spent.key_id})
      |> Map.merge(%{hour_limit: @messages_per_hour, day_recipient_limit: @recipients_per_day})
      |> Store.send()

    case sent do
      %{result: :sent} ->
        {:ok,
         %{
           id: message.id,
           box: box(sent.box),
           relationship: level(sent.relationship),
           epoch: sent.epoch,
           seq: sent.seq
         }}

      %{result: :rate_limited} ->
        {:error,
         {:rate_limited,
          %{
            limit_name: sent.limit_name,
            limit: limit(sent.limit_name),
            actual: sent.actual,
            retry_after: sent.retry_after
          }}}

      %{result: refused} when refused in [:token_required, :token_invalid, :token_replayed] ->
        {:error, :token_required}

      %{result: refused} ->
        {:error, refused}
    end
  end

  defp box("inbox"), do: :inbox
  defp box("requests"), do: :requests
  defp box("blocked"), do: :blocked

  defp level("unknown"), do: :unknown
  defp level("known"), do: :known
  defp level("verified"), do: :verified
  defp level("trusted"), do: :trusted

  defp limit("first_contact.messages_per_hour"), do: @messages_per_hour
  defp limit("first_contact.recipients_per_day"), do: @recipients_per_day

  # AG-59
  # AG-60
  # AG-61
  # AG-69
  @doc "How a sender stands with a recipient, in a transaction of its own: the relationship level of the pair, whether the recipient blocked the sender and whether the sender is at its first-contact limits."
  @spec standing(Scope.t(), id(), id()) :: {:ok, standing()} | {:error, term()}
  def standing(%Scope{} = scope, recipient_id, sender_id),
    do: Store.in_scope(scope, fn _status -> standing_in(recipient_id, sender_id) end)

  # AG-69
  @doc "How a sender stands with a recipient, inside the caller's scoped transaction; see `standing/3`."
  @spec standing_in(id(), id()) :: standing()
  def standing_in(recipient_id, sender_id) do
    read = Store.standing(recipient_id, sender_id)

    %{
      relationship: read.relationship,
      blocked: read.blocked,
      over_first_contact_rate:
        read.messages_last_hour >= @messages_per_hour or
          read.recipients_last_day >= @recipients_per_day
    }
  end

  # AG-38
  # AG-69
  @doc "The trust label of a message by the order of AG-69: `:blocked` for a sender the recipient blocked or Access suspended, `:spam` for one the carrying channel marked as unwanted or that is over its first-contact rate, `:authenticated` for a verified sender, otherwise `:unauthenticated`. The label is never derived from content."
  @spec trust_label(%{
          optional(:blocked) => boolean(),
          optional(:suspended) => boolean(),
          optional(:marked_spam) => boolean(),
          optional(:over_first_contact_rate) => boolean(),
          optional(:authenticated) => boolean()
        }) :: label()
  def trust_label(facts), do: Relay.Agents.TrustLabel.assign(facts)

  # AG-59
  # AG-73
  @doc "Applies a relationship level from Access to the copy of one tenant environment: `:owner` and `:peer` are the Access Party references of the agent that holds the level and of the agent it is about, `:level` one of `unknown`, `known`, `verified`, `trusted`, `:sequence` the pair's sequence number and `:source_event_ref` the event's identifier. Returns `:applied`, `:stale` for a sequence that is not above the stored one, or `:agent_not_found` when the environment does not hold both agents, which records nothing."
  @spec relationship_changed(Scope.t(), map()) ::
          {:ok, :applied | :stale | :agent_not_found} | {:error, term()}
  def relationship_changed(%Scope{} = scope, %{
        owner: owner,
        peer: peer,
        level: level,
        sequence: sequence,
        source_event_ref: event_ref
      })
      when is_binary(owner) and is_binary(peer) and level in @levels and is_integer(sequence) and
             sequence >= 0 and is_binary(event_ref) do
    with {:ok, %{id: owner_id}} <- Registry.credential(scope, owner),
         {:ok, %{id: peer_id}} <- Registry.credential(scope, peer) do
      Store.in_scope(scope, fn _status ->
        Store.apply_relationship(owner_id, peer_id, level, sequence, event_ref)
      end)
    else
      {:ok, nil} -> {:ok, :agent_not_found}
      {:error, error} -> {:error, error}
    end
  end

  # AG-61
  @doc "Blocks a sender for an agent (`blocked` true) or lifts the block, inside the caller's scoped transaction. Returns `{:blocked | :lifted | :unchanged, block}` with the block's `:state`, `:blocked_at` and `:lifted_at`, or `{:sender_not_found, nil}`."
  @spec set_block_in(id(), id(), boolean(), String.t()) ::
          {:blocked | :lifted | :unchanged, map()} | {:sender_not_found, nil}
  def set_block_in(owner_id, sender_id, blocked, actor_ref) when is_boolean(blocked) do
    case Store.set_block(owner_id, sender_id, blocked, actor_ref) do
      {:sender_not_found, _row} ->
        {:sender_not_found, nil}

      {result, row} ->
        {result,
         %{
           sender_id: sender_id,
           state: row["state"],
           blocked_at: row["blocked_at"],
           lifted_at: row["lifted_at"]
         }}
    end
  end

  # AG-61
  @doc "Reports a message of the reporter's mailbox as abuse inside the caller's scoped transaction, once; `statement` is the reporter's own statement or `nil`, `sender_ref` the reference of the sender the event carries. Returns `{:reported | :already_reported, reported_at, statement_attached}` or `{:not_found, nil, nil}`."
  @spec report_abuse_in(id(), id(), String.t(), String.t() | nil) ::
          {:reported | :already_reported | :not_found, DateTime.t() | nil, boolean() | nil}
  def report_abuse_in(reporter_id, record_id, sender_ref, statement),
    do: Store.report_abuse(Relay.Id.generate(), reporter_id, record_id, sender_ref, statement)

  # AG-67
  @doc "Reads the metadata of a message of a recipient inside the caller's scoped transaction, or `nil`."
  @spec message_in(id(), id()) :: map() | nil
  def message_in(recipient_id, record_id) do
    case Store.message(record_id) do
      %{"recipient_agent_id" => ^recipient_id} = message -> message
      _other -> nil
    end
  end

  # AG-56
  # AG-57
  # AG-67
  @doc "Reads a message of a recipient with its envelope as it is stored, sealed (`payload_ct` under `payload_tenant_key_id`), in a transaction of its own; `nil` when the recipient has no such message."
  @spec envelope(Scope.t(), id(), id()) :: {:ok, map() | nil} | {:error, term()}
  def envelope(%Scope{} = scope, recipient_id, record_id),
    do: Store.in_scope(scope, fn _status -> Store.envelope(recipient_id, record_id) end)

  # AG-59
  # API-56
  @doc "A page of the request box of a recipient, newest first, in a transaction of its own; at most `limit + 1` rows for the caller's list envelope."
  @spec requests(Scope.t(), id(), map() | nil, pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def requests(%Scope{} = scope, recipient_id, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.requests(recipient_id, cursor, limit) end)
end
