defmodule RelayWeb.Operator.CampaignController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.Campaigns

  # WF-62
  # OP-37
  @spec approve_audience(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def approve_audience(conn, params), do: run(conn, params, :approve_audience)

  # OP-47
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, params), do: run(conn, params, :resume)

  defp run(conn, %{"campaign_id" => text}, action) do
    %{operator_scope: scope, body: body} = conn.assigns
    actor = actor(conn)

    case path_id(text, Campaigns.prefix(), :campaign_not_found) do
      {:ok, id} -> idempotent(conn, fn -> Campaigns.operator(action, scope, id, body, actor) end)
      {:error, error} -> problem(conn, error)
    end
  end
end
