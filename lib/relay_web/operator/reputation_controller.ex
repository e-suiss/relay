defmodule RelayWeb.Operator.ReputationController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  # CH-87
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case Relay.EmailReputation.circuits(conn.assigns.operator_scope) do
      {:ok, rows} -> reply(conn, 200, %{"object" => "list", "data" => Enum.map(rows, &view/1)})
      {:error, _reason} -> problem(conn, Relay.Error.new(:service_unavailable, "try again"))
    end
  end

  # CH-41
  # CH-87
  @spec close(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def close(conn, %{"domain" => domain}) do
    domain = domain |> String.trim_trailing(".") |> String.downcase()
    idempotent(conn, fn -> run(conn, domain) end)
  end

  defp run(conn, domain) do
    reason = conn.assigns.body["reason"]

    case Relay.EmailReputation.close(conn.assigns.operator_scope, domain, reason, actor(conn)) do
      {:ok, circuit} ->
        {:ok, {200, view(circuit)}}

      {:error, :not_found} ->
        {:error, Relay.Error.new(:email_reputation_not_found, "no circuit for this domain")}

      {:error, :not_stopped} ->
        {:error, Relay.Error.new(:resource_conflict, "the circuit is not stopped")}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp view(row) do
    %{
      "object" => "email_reputation_circuit",
      "domain" => row["domain"],
      "state" => row["state"],
      "rates" => row["rates"],
      "warned_at" => row["warned_at"],
      "stopped_at" => row["stopped_at"],
      "closed_at" => row["closed_at"],
      "updated_at" => row["updated_at"]
    }
  end
end
