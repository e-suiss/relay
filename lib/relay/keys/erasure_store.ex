defmodule Relay.Keys.Erasure.Store do
  @moduledoc false

  alias Relay.Repo

  @erase [:erased, :already_erased, :held, :not_found]
  @destroy [:destroyed, :already_destroyed, :held, :not_allowed, :not_found]
  @retire [:retired, :already_destroyed, :held, :not_found]

  @spec subject_erase(Relay.Scope.t(), binary(), String.t(), map(), binary(), Relay.Actor.t()) ::
          {:ok, atom(), non_neg_integer()} | {:error, Relay.Error.t()}
  def subject_erase(scope, recipient_id, request_ref, plan, digest, actor) do
    scoped(scope, fn ->
      [%{"result" => result, "cancelled_deliveries" => cancelled}] =
        Repo.call!(
          "relay_fn.subject_erase",
          [recipient_id, request_ref, plan.destroy, plan.restrict, digest | actor_params(actor)]
        )

      {:ok, Repo.code!(result, @erase), cancelled || 0}
    end)
  end

  @spec tenant_key_destroy(Relay.Scope.t(), binary(), String.t(), binary(), Relay.Actor.t()) ::
          {:ok, atom()} | {:error, Relay.Error.t()}
  def tenant_key_destroy(scope, key_id, reason, digest, actor) do
    scoped(scope, fn ->
      [%{"tenant_key_destroy" => result}] =
        Repo.call!("relay_fn.tenant_key_destroy", [key_id, reason, digest | actor_params(actor)])

      {:ok, Repo.code!(result, @destroy)}
    end)
  end

  @spec subject_key_retire(Relay.Scope.t(), binary(), binary(), Relay.Actor.t()) ::
          {:ok, atom()} | {:error, Relay.Error.t()}
  def subject_key_retire(scope, key_id, digest, actor) do
    scoped(scope, fn ->
      [%{"subject_key_retire" => result}] =
        Repo.call!("relay_fn.subject_key_retire", [key_id, digest | actor_params(actor)])

      {:ok, Repo.code!(result, @retire)}
    end)
  end

  defp actor_params(actor), do: Relay.Actor.params(actor)

  defp scoped(scope, fun) do
    case Repo.in_scope(scope, fn _status -> fun.() end) do
      {:ok, result} -> result
      {:error, %Relay.Error{}} = error -> error
      {:error, _} -> {:error, Relay.Error.new(:database_error, "erasure transaction failed")}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, Relay.Error.new(:database_error, "erasure transaction failed")}
  end
end
