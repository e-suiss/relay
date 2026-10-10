defmodule RelayWeb.ReadinessTest do
  use RelayWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    pid = Sandbox.start_owner!(Relay.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  test "T-63: readiness checks PostgreSQL", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/readyz") |> json_response(200)
  end
end
