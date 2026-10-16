defmodule Relay.Scope do
  @moduledoc """
  The tenant and environment a unit of work runs in. A scope is never inherited: every transaction establishes it as its first statement through `Relay.Repo.in_scope/3`, and every job, process and task boundary carries it explicitly and rebuilds it with `from_job_args/1`.
  """

  @enforce_keys [:tenant_id, :environment]
  defstruct [:tenant_id, :environment]

  @type t :: %__MODULE__{tenant_id: <<_::128>>, environment: Relay.Environment.t()}

  # TN-13 (5)
  @doc "Builds a scope from a 16-byte tenant identifier and an environment."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(<<_::128>> = tenant_id, environment) do
    with {:ok, environment} <- Relay.Environment.cast(environment) do
      {:ok, %__MODULE__{tenant_id: tenant_id, environment: environment}}
    end
  end

  def new(_tenant_id, _environment),
    do: {:error, Relay.Error.new(:invalid_scope, "a scope needs a 16-byte tenant identifier")}

  @doc "Builds a scope and raises on invalid input."
  @spec new!(term(), term()) :: t()
  def new!(tenant_id, environment) do
    case new(tenant_id, environment) do
      {:ok, scope} -> scope
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  # T-15
  # TN-13 (5)
  @doc "Returns the job arguments that carry a scope across a queue boundary: identifiers only."
  @spec to_job_args(t()) :: %{String.t() => String.t()}
  def to_job_args(%__MODULE__{tenant_id: tenant_id, environment: environment}) do
    %{
      "tenant_id" => uuid_text(tenant_id),
      "environment" => Relay.Environment.dump(environment)
    }
  end

  @doc "Rebuilds a scope from job arguments written by `to_job_args/1`."
  @spec from_job_args(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def from_job_args(%{"tenant_id" => tenant_id, "environment" => environment}) do
    case Ecto.UUID.dump(tenant_id) do
      {:ok, binary} -> new(binary, environment)
      :error -> invalid_args()
    end
  end

  def from_job_args(_args), do: invalid_args()

  # TN-16 (3)
  @doc "Returns true if a row's tenant and environment columns belong to the scope."
  @spec covers?(t(), term(), term()) :: boolean()
  def covers?(%__MODULE__{tenant_id: tenant_id, environment: environment}, row_tenant, row_env) do
    row_tenant == tenant_id and row_env == Relay.Environment.dump(environment)
  end

  @doc "Returns the text form of the tenant identifier, used in log metadata and signal topics."
  @spec tenant_text(t()) :: String.t()
  def tenant_text(%__MODULE__{tenant_id: tenant_id}), do: uuid_text(tenant_id)

  defp uuid_text(binary) do
    {:ok, text} = Ecto.UUID.load(binary)
    text
  end

  defp invalid_args,
    do: {:error, Relay.Error.new(:invalid_scope, "job arguments carry no valid scope")}

  defimpl Inspect do
    def inspect(scope, _opts),
      do: "#Relay.Scope<#{Relay.Scope.tenant_text(scope)}/#{scope.environment}>"
  end
end
