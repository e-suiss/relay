defmodule Relay.Tenancy.Context do
  @moduledoc """
  The tenant transaction context. Work for a tenant runs in `within/3`, which establishes the scope as the transaction's first statement and hands the work the tenant status; the status decides whether new work may start (OP-68 (5)). Job arguments carry the scope as identifiers and the context is rebuilt from them at every job boundary.
  """

  alias Relay.Scope

  alias Relay.Tenancy.Store

  @type status :: :active | :suspended | :closed

  # TN-13 (2)
  # TN-13 (5)
  @doc "Runs `work` in a transaction scoped to the tenant environment; see `Relay.Repo.in_scope/3`."
  @spec within(Scope.t(), (status() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def within(%Scope{} = scope, work, _opts \\ []), do: Store.in_scope(scope, work)

  # TN-10
  @doc "Returns `:ok` for an active tenant and a `:tenant_inactive` error otherwise."
  @spec require_active(status()) :: :ok | {:error, Relay.Error.t()}
  def require_active(:active), do: :ok

  def require_active(status) when status in [:suspended, :closed],
    do: {:error, Relay.Error.new(:tenant_inactive, "tenant is not active", %{status: status})}

  # T-15
  @doc "Builds job arguments: the scope plus identifiers, nothing else."
  @spec job_args(Scope.t(), %{optional(String.t()) => String.t()}) :: %{String.t() => String.t()}
  def job_args(%Scope{} = scope, ids \\ %{}) when is_map(ids),
    do: Map.merge(ids, Scope.to_job_args(scope))

  # TN-13 (5)
  @doc "Rebuilds the scope at a job boundary."
  @spec from_job_args(map()) :: {:ok, Scope.t()} | {:error, Relay.Error.t()}
  def from_job_args(args), do: Scope.from_job_args(args)
end
