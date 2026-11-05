defmodule Relay.Messaging.Store do
  @moduledoc """
  Data access of the messaging channels: a recipient's conversation on an installation (`relay.messaging_targets`, CH-62), the message of a subject in a conversation (`relay.messaging_messages`, CH-23), the channel identities and installations they belong to, and the outbox events of interactions. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`; writes call the `relay_fn` functions.
  """

  alias Relay.Repo

  @type id :: Relay.Id.t()

  @account_columns "id, channel::text AS channel, provider, ownership, credential_ref_id, state, verification_state, settings, version"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls back the caller's scoped transaction with `value`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  # CH-62
  @doc "Puts the active conversation of a recipient on a channel; an earlier one is replaced."
  @spec target_put(id(), id(), String.t(), id(), binary()) ::
          {:created | :replaced | :recipient_not_found | :account_not_found | :key_not_found,
           id() | nil}
  def target_put(id, recipient_id, channel, account_id, target_ct) do
    [row] =
      Repo.call!("relay_fn.messaging_target_put", [
        id,
        recipient_id,
        channel,
        account_id,
        target_ct
      ])

    {Repo.code!(row["result"], [
       :created,
       :replaced,
       :recipient_not_found,
       :account_not_found,
       :key_not_found
     ]), row["target_id"]}
  end

  # CH-11
  # CH-62
  @doc "Soft disables the active conversation of a recipient on a channel and appends `messaging_target.disabled`."
  @spec target_disable(id(), String.t(), String.t()) :: {:disabled | :not_found, id() | nil}
  def target_disable(recipient_id, channel, rule_id) do
    [row] = Repo.call!("relay_fn.messaging_target_disable", [recipient_id, channel, rule_id])
    {Repo.code!(row["result"], [:disabled, :not_found]), row["target_id"]}
  end

  # CH-62
  @doc "The active conversation of a recipient on a channel, or `nil`."
  @spec target(id(), String.t()) :: map() | nil
  def target(recipient_id, channel) do
    one(
      "SELECT id, recipient_id, channel::text AS channel, provider_account_id, target_ct, state, created_at, updated_at FROM relay.messaging_targets WHERE recipient_id = $1 AND channel = $2::relay.channel AND state = 'active'",
      [recipient_id, channel]
    )
  end

  # CH-62
  @doc "A conversation by identifier, whatever its state, or `nil`."
  @spec target_by_id(id()) :: map() | nil
  def target_by_id(id) do
    one(
      "SELECT id, recipient_id, channel::text AS channel, provider_account_id, state, disabled_rule_id, deleted_at, created_at, updated_at FROM relay.messaging_targets WHERE id = $1",
      [id]
    )
  end

  # CH-23
  @doc "The provider message reference of a subject's message in a conversation, or `nil`."
  @spec message_ref(id(), binary()) :: String.t() | nil
  def message_ref(target_id, topic_key) do
    case one(
           "SELECT provider_message_ref FROM relay.messaging_messages WHERE target_id = $1 AND topic_key = $2 AND provider_message_ref <> 'erased'",
           [target_id, topic_key]
         ) do
      %{"provider_message_ref" => ref} -> ref
      nil -> nil
    end
  end

  # CH-23
  @doc "Records the provider message of a subject in a conversation."
  @spec message_put(id(), binary(), String.t(), id()) :: :recorded | :target_not_found
  def message_put(target_id, topic_key, ref, delivery_id) do
    [row] =
      Repo.call!("relay_fn.messaging_message_put", [
        Relay.Id.generate(),
        target_id,
        topic_key,
        ref,
        delivery_id
      ])

    Repo.code!(row["messaging_message_put"], [:recorded, :target_not_found])
  end

  # CH-62
  @doc "The delivery whose message on an installation has the provider reference, or `nil`."
  @spec message_delivery(id(), String.t()) :: id() | nil
  def message_delivery(account_id, ref) do
    case one(
           "SELECT delivery_id FROM relay.messaging_messages WHERE provider_account_id = $1 AND provider_message_ref = $2 ORDER BY updated_at DESC LIMIT 1",
           [account_id, ref]
         ) do
      %{"delivery_id" => id} -> id
      nil -> nil
    end
  end

  # CH-23
  @doc "The subject of a delivery: its type, identifier and message class, or `nil` without a subject."
  @spec subject(id()) :: map() | nil
  def subject(delivery_id) do
    one(
      "SELECT n.subject_type, n.subject_id, n.message_class::text AS message_class FROM relay.deliveries d JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment AND n.id = d.notification_id WHERE d.id = $1 AND n.subject_type IS NOT NULL AND n.subject_id IS NOT NULL",
      [delivery_id]
    )
  end

  # C-26
  @doc "A channel identity, or `nil`."
  @spec identity(id()) :: map() | nil
  def identity(id) do
    one(
      "SELECT id, channel::text AS channel, kind, app_ref, secret_ref_id, state FROM relay.channel_identities WHERE id = $1",
      [id]
    )
  end

  # CH-62
  @doc "A provider account by identifier, or `nil`."
  @spec account(id()) :: map() | nil
  def account(id),
    do: one("SELECT #{@account_columns} FROM relay.provider_accounts WHERE id = $1", [id])

  # CH-62
  @doc "The installation of a channel identity in a workspace: its provider account, or `nil`."
  @spec installation(String.t(), id(), String.t()) :: map() | nil
  def installation(provider, identity_id, workspace) do
    one(
      "SELECT #{@account_columns} FROM relay.provider_accounts WHERE provider = $1 AND settings->>'identity_id' = $2 AND settings->>'workspace_id' = $3 ORDER BY created_at DESC LIMIT 1",
      [provider, Relay.Id.to_string(identity_id), workspace]
    )
  end

  # CH-4
  @doc "The providers the scope has active provider accounts of."
  @spec providers() :: [String.t()]
  def providers do
    %Postgrex.Result{rows: rows} =
      Repo.scoped_query!(
        "SELECT DISTINCT provider FROM relay.provider_accounts WHERE state = 'active' ORDER BY provider",
        []
      )

    Enum.map(rows, &hd/1)
  end

  # CH-62
  # CH-4
  @doc "Appends an outbox event on a stream."
  @spec event(String.t(), String.t(), map()) :: :appended
  def event(type, stream_key, payload) do
    [row] =
      Repo.call!("relay_fn.outbox_append", [Relay.Id.generate(), type, stream_key, payload, nil])

    Repo.code!(row["result"], [:appended])
  end

  defp one(sql, params) do
    case Repo.scoped_query!(sql, params) do
      %Postgrex.Result{columns: columns, rows: [row | _]} -> columns |> Enum.zip(row) |> Map.new()
      %Postgrex.Result{rows: []} -> nil
    end
  end
end
