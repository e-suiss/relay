defmodule Relay.Platform.Store do
  @moduledoc false

  alias Relay.Repo

  @spec ping() :: :ok | {:error, atom()}
  def ping do
    case Repo.query("SELECT 1", [], timeout: 1_000) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :database_unreachable}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :database_unreachable}
  end
end
