defmodule Relay.Agents.MessageStore do
  @moduledoc """
  Data access for the messages of a mailbox: `relay_fn.mailbox_message_append`, which writes a message record with its trust label and the event that announces it, or holds a `blocked` message without an event, the read of the sealed content of records and the tenant's link allow list. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @setting "agent.link_origins"

  @type id :: Relay.Id.t()

  # AG-40
  # AG-41
  @doc "The tenant's `agent.link_origins` setting: the origins an action link of a message may point to; empty while it is unset."
  @spec link_origins() :: [String.t()]
  def link_origins do
    case Repo.call!("relay_fn.setting_resolve", [nil, [@setting]]) do
      [%{"value" => origins} | _rest] when is_list(origins) -> Enum.filter(origins, &is_binary/1)
      _unset -> []
    end
  end

  # C-76
  # AG-38
  # AG-69
  # INV-12
  # AG-61
  # AG-84
  @doc "Appends a message record with its trust label, its sealed payload and its sealed referenced content, and the outbox event that announces it: `mailbox.record_appended`, or `mailbox.record_flagged` for a `spam` message. A `blocked` message is recorded held with its sealed payload alone: it takes its position, is never leased or read and has no event."
  @spec append(map()) ::
          {:appended, pos_integer(), pos_integer()} | :mailbox_not_found | :mailbox_inactive
  def append(record) do
    [row] =
      Repo.call!("relay_fn.mailbox_message_append", [
        record.id,
        record.mailbox_id,
        Atom.to_string(record.trust_label),
        record.payload_ct,
        record.content_ref_ct,
        record.key_id,
        record.digest,
        record.traceparent
      ])

    case Repo.code!(row["result"], [:appended, :mailbox_not_found, :mailbox_inactive]) do
      :appended -> {:appended, row["epoch"], row["seq"]}
      other -> other
    end
  end

  # C-76
  # AG-40
  @doc "The trust label and the sealed content of `records` (rows with `id` and `created_at`), by record identifier; the referenced content only with `referenced?`."
  @spec contents([map()], boolean()) :: %{id() => map()}
  def contents([], _referenced?), do: %{}

  def contents(records, referenced?) when is_boolean(referenced?) do
    ids = Enum.map(records, & &1["id"])
    times = Enum.map(records, & &1["created_at"])

    sql = """
    SELECT r.id, r.trust_label, r.payload_ct, r.payload_tenant_key_id,
      CASE WHEN $4 THEN r.content_ref_ct END AS content_ref_ct
    FROM relay.mailbox_records r
    WHERE r.id = ANY ($1) AND r.kind IN ('message', 'waitpoint_event')
      AND r.created_at BETWEEN $2 AND $3
    """

    params = [ids, Enum.min(times, DateTime), Enum.max(times, DateTime), referenced?]
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)

    Map.new(rows, fn row ->
      content = columns |> Enum.zip(row) |> Map.new()
      {content["id"], content}
    end)
  end
end
