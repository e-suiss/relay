defmodule Relay.Keys.Erasure.Store do
  @moduledoc false

  alias Relay.Repo

  @erase %{
    "erased" => :erased,
    "already_erased" => :already_erased,
    "held" => :held,
    "not_found" => :not_found
  }

  @destroy %{
    "destroyed" => :destroyed,
    "already_destroyed" => :already_destroyed,
    "held" => :held,
    "not_allowed" => :not_allowed
  }

  @spec subject_erase(map(), binary(), String.t(), map(), binary(), map()) ::
          {:ok, atom(), non_neg_integer()} | {:error, Relay.Error.t()}
  def subject_erase(scope, recipient_id, request_ref, plan, digest, actor) do
    scoped(scope, fn ->
      """
      SELECT result, cancelled_deliveries
      FROM relay_fn.subject_erase($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """
      |> Repo.query!([
        recipient_id,
        request_ref,
        plan.destroy,
        plan.restrict,
        digest | actor_params(actor)
      ])
      |> case do
        %{rows: [[result, cancelled]]} -> {:ok, Map.fetch!(@erase, result), cancelled || 0}
      end
    end)
  end

  @spec tenant_key_destroy(map(), binary(), String.t(), binary(), map()) ::
          {:ok, atom()} | {:error, Relay.Error.t()}
  def tenant_key_destroy(scope, key_id, reason, digest, actor) do
    scoped(scope, fn ->
      "SELECT relay_fn.tenant_key_destroy($1, $2, $3, $4, $5, $6, $7)"
      |> Repo.query!([key_id, reason, digest | actor_params(actor)])
      |> case do
        %{rows: [[result]]} -> {:ok, Map.fetch!(@destroy, result)}
      end
    end)
  end

  defp actor_params(actor),
    do: [actor.kind, actor.ref, actor.on_behalf_of, Map.get(actor, :access_record_ref)]

  defp scoped(scope, fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT relay_fn.ctx_set($1, $2)", [scope.tenant_id, scope.environment])
      fun.()
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} -> {:error, Relay.Error.new(:database_error, "erasure transaction failed")}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, Relay.Error.new(:database_error, "erasure transaction failed")}
  end
end
