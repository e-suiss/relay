defmodule Relay.Platform.Leadership.Store do
  @moduledoc false

  alias Relay.Repo

  @spec acquire(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t(), pos_integer() | nil} | {:error, Relay.Error.t()}
  def acquire(name, node, ttl_ms) do
    "SELECT result, fencing_token FROM relay_ops.singleton_acquire($1, $2, $3::bigint * interval '1 millisecond')"
    |> Repo.query([name, node, ttl_ms])
    |> case do
      {:ok, %{rows: [[result, token]]}} -> {:ok, result, token}
      other -> failure(other)
    end
  end

  @spec save(String.t(), pos_integer(), map()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def save(name, token, state) do
    case Repo.query("SELECT relay_ops.singleton_save($1, $2, $3)", [name, token, state]) do
      {:ok, %{rows: [[result]]}} -> {:ok, result}
      other -> failure(other)
    end
  end

  @spec load_state(String.t()) :: {:ok, map() | nil} | {:error, Relay.Error.t()}
  def load_state(name) do
    case Repo.query("SELECT state FROM relay.singleton_tasks WHERE name = $1", [name]) do
      {:ok, %{rows: [[state]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> {:ok, nil}
      other -> failure(other)
    end
  end

  defp failure(other),
    do:
      {:error,
       Relay.Error.new(:database_error, "leadership query failed", %{reason: reason(other)})}

  defp reason({:error, %{postgres: %{code: code}}}), do: code
  defp reason({:error, %DBConnection.ConnectionError{}}), do: :connection
  defp reason(_other), do: :unexpected
end
