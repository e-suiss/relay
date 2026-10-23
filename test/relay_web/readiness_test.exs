defmodule RelayWeb.ReadinessTest do
  use RelayWeb.ConnCase, async: false

  import Mox

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup :verify_on_exit!

  setup do
    pid = Sandbox.start_owner!(Relay.Repo, shared: true)
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)

    on_exit(fn ->
      Application.put_env(:relay, :keys, previous)
      Sandbox.stop_owner(pid)
    end)
  end

  test "T-63: readiness checks PostgreSQL and the key store", %{conn: conn} do
    expect(Relay.KeysMock, :ping, fn -> :ok end)
    assert %{"status" => "ok"} = conn |> get("/readyz") |> json_response(200)
  end

  test "TN-66: a key store that does not answer makes the node unready", %{conn: conn} do
    expect(Relay.KeysMock, :ping, fn ->
      {:error, Relay.Error.new(:key_store_unavailable, "key store program exited")}
    end)

    assert %{"status" => "not_ready"} = conn |> get("/readyz") |> json_response(503)
  end
end
