defmodule Relay.Platform.VirtualClockStore do
  @moduledoc """
  Data access for the virtual clock: `relay_fn.virtual_clock_advance` and `relay_fn.virtual_clock_get`, inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # TN-8
  # X-27
  @doc "Advances the virtual offset of the established `test` scope."
  @spec advance(integer(), <<_::256>>, Actor.t()) ::
          {:advanced, non_neg_integer(), DateTime.t()} | :not_test_environment | :invalid_step
  def advance(by_ms, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.virtual_clock_advance", [by_ms, digest | Actor.params(actor)])

    case Repo.code!(row["result"], [:advanced, :not_test_environment, :invalid_step]) do
      :advanced -> {:advanced, row["offset_ms"], row["business_now"]}
      other -> other
    end
  end

  # X-27
  @doc "Reads the virtual offset and business time of the established scope."
  @spec get() :: {:ok, non_neg_integer(), DateTime.t()} | :not_test_environment
  def get do
    [row] = Repo.call!("relay_fn.virtual_clock_get", [])

    case Repo.code!(row["result"], [:ok, :not_test_environment]) do
      :ok -> {:ok, row["offset_ms"], row["business_now"]}
      :not_test_environment -> :not_test_environment
    end
  end
end
