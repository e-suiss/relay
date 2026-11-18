defmodule Relay.Inbox.Live.Store do
  @moduledoc """
  Data access of the inbox on the send path: scoped transactions and the registration of a recipient's content key (`relay_fn.subject_key_create`). Every function except `in_scope/2` runs inside the caller's `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # OP-18
  # IN-44
  @doc "Registers a subject data key of a recipient and retention class, or returns the active one."
  @spec subject_key_create(Relay.Id.t(), Relay.Id.t(), String.t(), binary(), Relay.Id.t()) ::
          {:created | :exists | :recipient_not_found | :recipient_deleted, Relay.Id.t() | nil}
  def subject_key_create(id, recipient_id, retention_class, wrapped_dek, wrapping_key_id) do
    [row] =
      Repo.call!("relay_fn.subject_key_create", [
        id,
        recipient_id,
        retention_class,
        wrapped_dek,
        wrapping_key_id
      ])

    {Repo.code!(row["result"], [:created, :exists, :recipient_not_found, :recipient_deleted]),
     row["subject_key_id"]}
  end

  # C-24
  # AG-34
  # AG-35
  # IN-6
  @doc "Per notification of `notification_ids`: its sender type and, for a notification about a waitpoint, the waitpoint's identifier, kind, profile, state, subject digest, sealed content and key, resolution time and the kind and identifier of the recipient whose response resolved it."
  @spec annotations([Relay.Id.t()]) :: [map()]
  def annotations([]), do: []

  def annotations(notification_ids) do
    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(
        """
        SELECT n.id AS notification_id, n.sender_type, w.id AS waitpoint_id, w.kind, w.profile,
          w.state, w.subject_digest, w.content_ct, w.field_key_id, w.resolved_at,
          r.responder_recipient_id, rr.kind AS responder_kind
        FROM relay.notifications n
        LEFT JOIN relay.waitpoints w ON n.subject_type = 'waitpoint'
          AND w.tenant_id = n.tenant_id AND w.environment = n.environment
          AND w.id::text = n.subject_id
        LEFT JOIN relay.waitpoint_responses r ON r.tenant_id = w.tenant_id
          AND r.environment = w.environment AND r.id = w.resolution_response_id
        LEFT JOIN relay.recipients rr ON rr.tenant_id = r.tenant_id
          AND rr.environment = r.environment AND rr.id = r.responder_recipient_id
        WHERE n.id = ANY ($1)
        """,
        [Enum.uniq(notification_ids)]
      )

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
