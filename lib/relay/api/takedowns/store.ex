defmodule Relay.Api.Takedowns.Store do
  @moduledoc """
  Data access of takedowns. A takedown is written by `relay_fn.takedown_apply` and lifted by `relay_fn.takedown_lift`, each with its audit record in the same transaction. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @columns """
  k.tenant_id, k.environment, k.id, k.target_kind, k.notification_id, k.template_id,
  k.sender_identity_id, k.reason, k.state, k.restores, k.hidden_items, k.cancelled_deliveries,
  k.lift_reason, k.lifted_at, k.created_at, k.updated_at
  """

  @type digest :: <<_::256>>

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current transaction back with `value`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  # TN-60
  # TN-47
  @doc "Takes a target down: `kind` is `message`, `template` or `sender_identity` and `target_id` the notification, template or sender identity."
  @spec take_down(Relay.Id.t(), String.t(), Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          {:applied | :already_active | :not_found, Relay.Id.t() | nil}
  def take_down(id, kind, target_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.takedown_apply",
        [id, kind, target_id, reason, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:applied, :already_active, :not_found]), row["takedown_id"]}
  end

  # TN-60
  # TN-47
  @doc "Lifts an active takedown and restores what it changed."
  @spec lift(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :lifted | :already_lifted | :not_found
  def lift(id, reason, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.takedown_lift", [id, reason, digest] ++ Actor.params(actor))
    Repo.code!(row["result"], [:lifted, :already_lifted, :not_found])
  end

  @doc "Reads one takedown of the established scope, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    "SELECT #{@columns} FROM relay.takedowns k WHERE k.id = $1"
    |> Repo.scoped_query!([id])
    |> maps()
    |> List.first()
  end

  @doc "Lists the takedowns of the established scope after `after_id`, oldest first."
  @spec list(Relay.Id.t() | nil, pos_integer()) :: [map()]
  def list(after_id, limit) do
    """
    SELECT #{@columns} FROM relay.takedowns k
    WHERE ($1::uuid IS NULL OR k.id > $1::uuid)
    ORDER BY k.id LIMIT $2
    """
    |> Repo.scoped_query!([after_id, limit])
    |> maps()
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
