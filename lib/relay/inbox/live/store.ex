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
end
