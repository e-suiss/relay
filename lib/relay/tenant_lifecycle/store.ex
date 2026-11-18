defmodule Relay.TenantLifecycle.Store do
  @moduledoc false

  alias Relay.Actor
  alias Relay.Repo

  @columns "tenant_id, environment::text AS environment, id, state, reason, formats, export_prefix, export_manifest, export_ready_at, shred_after, confirmed_at, confirmation_ref, shred_started_at, shredded_at, created_at, updated_at"

  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  @spec request(map(), <<_::256>>, Actor.t()) ::
          {:requested | :exists | :not_allowed, Relay.Id.t() | nil}
  def request(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_close_request",
        [attrs.id, attrs.reason, attrs.formats, attrs.export_prefix, attrs.step_up_ref, digest] ++
          Actor.params(actor)
      )

    {Repo.code!(row["result"], [:requested, :exists, :not_allowed]), row["closure_id"]}
  end

  @spec get() :: map() | nil
  def get do
    "SELECT #{@columns} FROM relay.tenant_closures"
    |> Repo.scoped_query!([])
    |> rows()
    |> List.first()
  end

  @spec export_ready(Relay.Id.t(), map(), <<_::256>>, Actor.t()) ::
          :ready | :not_exporting | :not_found
  def export_ready(id, manifest, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_close_export_ready",
        [id, manifest, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_close_export_ready"], [:ready, :not_exporting, :not_found])
  end

  @spec confirm(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          :confirmed | :already_confirmed | :not_ready | :not_found
  def confirm(id, confirmation_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_close_confirm",
        [id, confirmation_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_close_confirm"], [
      :confirmed,
      :already_confirmed,
      :not_ready,
      :not_found
    ])
  end

  @spec shred_begin(Relay.Id.t(), String.t() | nil, <<_::256>>, Actor.t()) ::
          :started | :already_started | :not_due | :not_ready | :not_found
  def shred_begin(id, step_up_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_close_shred_begin",
        [id, step_up_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_close_shred_begin"], [
      :started,
      :already_started,
      :not_due,
      :not_ready,
      :not_found
    ])
  end

  @spec shred_finish(Relay.Id.t()) :: :shredded | :already_shredded | :not_shredding | :not_found
  def shred_finish(id) do
    [row] = Repo.call!("relay_fn.tenant_close_shred_finish", [id])

    Repo.code!(row["tenant_close_shred_finish"], [
      :shredded,
      :already_shredded,
      :not_shredding,
      :not_found
    ])
  end

  defp rows(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
