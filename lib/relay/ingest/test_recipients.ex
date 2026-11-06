defmodule Relay.Ingest.TestRecipients do
  @moduledoc """
  Data access of the test recipient list and the test send quota (API-61). A test recipient is a subscriber, or one of its devices, that the tenant adds as `pending` and that becomes `verified` only when the subscriber confirms it with its own subscriber token within the verification window; a pending entry whose window has passed is `expired` and no longer counts. The list holds at most the contract's `test_send.max_test_recipients` pending and verified entries. A removed entry, and every entry of an erased subscriber, is kept as `removed`; rows are never deleted. Test sends count against their own daily counter, never against the sending quota. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @row """
  SELECT t.tenant_id, t.environment, t.id, t.recipient_id, t.device_id, t.state, t.verify_by,
    t.verified_at, t.removed_at, t.created_at
  FROM relay.test_recipients t
  """
  @listed "(t.state = 'verified' OR (t.state = 'pending' AND t.verify_by > now()))"
  @added [:added, :exists, :limit_reached, :recipient_not_found, :device_not_found]
  @confirmed [:verified, :already_verified, :expired, :not_found]
  @removed [:removed, :already_removed, :not_found]

  @type id :: Relay.Id.t()

  # API-61
  # TN-46
  @doc "Adds a subscriber, or one of its devices, as a pending test recipient; returns the result and the entry's identifier."
  @spec add(id(), id() | nil, pos_integer(), pos_integer(), binary(), Actor.t()) ::
          {atom(), id() | nil}
  def add(recipient_id, device_id, limit, window_s, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.test_recipient_add",
        [Relay.Id.generate(), recipient_id, device_id, limit, window_s, digest] ++
          Actor.params(actor)
      )

    {Repo.code!(row["result"], @added), row["test_recipient_id"]}
  end

  # API-61
  # TN-46
  @doc "Confirms a pending entry of the subscriber `recipient_id`."
  @spec confirm(Relay.Id.t(), Relay.Id.t(), binary(), Actor.t()) ::
          :verified | :already_verified | :expired | :not_found
  def confirm(id, recipient_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.test_recipient_confirm",
        [id, recipient_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["test_recipient_confirm"], @confirmed)
  end

  # API-61
  # TN-46
  @doc "Removes an entry; the row is kept as `removed`."
  @spec remove(Relay.Id.t(), binary(), Actor.t()) :: :removed | :already_removed | :not_found
  def remove(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.test_recipient_remove", [id, digest] ++ Actor.params(actor))
    Repo.code!(row["test_recipient_remove"], @removed)
  end

  # API-61
  @doc "Consumes `count` notifications of the day's test send quota of at most `limit`; returns the result and the day's count."
  @spec consume(pos_integer(), non_neg_integer()) :: {:consumed | :exhausted, non_neg_integer()}
  def consume(count, limit) do
    [row] = Repo.call!("relay_fn.test_send_consume", [count, limit])
    {Repo.code!(row["result"], [:consumed, :exhausted]), row["used"]}
  end

  # API-61
  @doc "Reads an entry, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id), do: List.first(all(@row <> " WHERE t.id = $1", [id]))

  # API-61
  @doc "The pending and verified entries, newest first; only the subscriber's own with `recipient_id`."
  @spec listed(Relay.Id.t() | nil) :: [map()]
  def listed(nil), do: all(@row <> " WHERE #{@listed} ORDER BY t.created_at DESC, t.id DESC", [])

  def listed(recipient_id) do
    sql =
      @row <> " WHERE t.recipient_id = $1 AND #{@listed} ORDER BY t.created_at DESC, t.id DESC"
    all(sql, [recipient_id])
  end

  # API-61
  @doc "The verified entries among `ids`."
  @spec verified([Relay.Id.t()]) :: [map()]
  def verified(ids), do: all(@row <> " WHERE t.id = ANY ($1) AND t.state = 'verified'", [ids])

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
