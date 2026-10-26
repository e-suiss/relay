defmodule Relay.Inbox do
  @moduledoc """
  The inbox, badges and the realtime feed, on top of the durable record core shared with agent and API client mailboxes (`Relay.Inbox.Mailbox`). Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Inbox.Mailbox

  # AG-64
  # IN-1
  @doc "Opens the owner's mailbox if it has none; see `Relay.Inbox.Mailbox.ensure/3`."
  @spec ensure_mailbox(Relay.Scope.t(), Mailbox.owner_kind(), Relay.Id.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate ensure_mailbox(scope, owner_kind, owner_ref), to: Mailbox, as: :ensure

  # C-68
  @doc "Appends a record to a mailbox; see `Relay.Inbox.Mailbox.append/2`."
  @spec append(Relay.Scope.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate append(scope, record), to: Mailbox

  # IN-22
  @doc "Reads records after a sequence number; see `Relay.Inbox.Mailbox.read/5`."
  @spec read(Relay.Scope.t(), Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, Mailbox.page()} | {:resync_required, map()} | :not_found | {:error, term()}
  defdelegate read(scope, mailbox_id, epoch, since_seq, limit), to: Mailbox

  # AG-22
  @doc "Leases records; see `Relay.Inbox.Mailbox.lease/5`."
  @spec lease(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate lease(scope, mailbox_id, holder, max, opts), to: Mailbox

  # AG-21
  @doc "Acknowledges leased records; see `Relay.Inbox.Mailbox.ack/4`."
  @spec ack(Relay.Scope.t(), Relay.Id.t(), [Relay.Id.t()], String.t()) ::
          {:ok, [{Relay.Id.t(), atom()}]} | {:error, term()}
  defdelegate ack(scope, mailbox_id, record_ids, holder), to: Mailbox

  # IN-22
  @doc "Moves a reader cursor forward; see `Relay.Inbox.Mailbox.advance_cursor/5`."
  @spec advance_cursor(
          Relay.Scope.t(),
          Relay.Id.t(),
          String.t(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, atom()} | {:error, term()}
  defdelegate advance_cursor(scope, mailbox_id, consumer, epoch, seq), to: Mailbox

  # IN-26
  @doc "Starts a new epoch of a mailbox stream; see `Relay.Inbox.Mailbox.bump_epoch/5`."
  @spec bump_epoch(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate bump_epoch(scope, mailbox_id, reason, record_digest, actor), to: Mailbox

  # AG-5
  @doc "Changes a mailbox state; see `Relay.Inbox.Mailbox.set_state/4`."
  @spec set_mailbox_state(
          Relay.Scope.t(),
          Relay.Id.t(),
          :active | :suspended | :deleted,
          String.t() | nil
        ) ::
          {:ok, atom()} | {:error, term()}
  defdelegate set_mailbox_state(scope, mailbox_id, state, reason), to: Mailbox, as: :set_state
end
