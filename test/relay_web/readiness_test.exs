defmodule RelayWeb.ReadinessTest do
  use RelayWeb.ConnCase, async: false

  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Datasets
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Snapshot

  @moduletag :integration

  setup :verify_on_exit!

  setup do
    pid = Sandbox.start_owner!(Relay.Repo, shared: true)
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)

    on_exit(fn ->
      forget_channel_parameters()
      Application.put_env(:relay, :keys, previous)
      Sandbox.stop_owner(pid)
    end)
  end

  defp forget_channel_parameters,
    do:
      Datasets.Cache.invalidate(
        Datasets.Cache,
        {Datasets.installation_scope(), "channel_parameters"}
      )

  defp load_channel_parameters do
    forget_channel_parameters()
    {:ok, %{"channel_parameters" => _}} = Datasets.load_package(RelayTest.TenantFixture.actor())
    assert {:ok, _} = Datasets.channel_parameters()
  end

  test "T-63: readiness checks PostgreSQL and the key store", %{conn: conn} do
    load_channel_parameters()
    Cache.put(Snapshot.new(0, []))
    on_exit(fn -> Cache.forget() end)
    expect(Relay.KeysMock, :ping, fn -> :ok end)
    assert %{"status" => "ok"} = conn |> get("/readyz") |> json_response(200)
  end

  test "TN-38: a node that has not read the kill switch state is not ready", %{conn: conn} do
    Cache.forget()
    expect(Relay.KeysMock, :ping, fn -> :ok end)

    assert %{"status" => "kill_switch_unknown"} =
             conn |> get("/readyz") |> json_response(503)
  end

  test "TN-66: a key store that does not answer makes the node unready", %{conn: conn} do
    expect(Relay.KeysMock, :ping, fn ->
      {:error, Relay.Error.new(:key_store_unavailable, "key store program exited")}
    end)

    assert %{"status" => "not_ready"} = conn |> get("/readyz") |> json_response(503)
  end

  test "CH-69: a node without an active channel_parameters version is not ready", %{conn: conn} do
    Cache.put(Snapshot.new(0, []))
    on_exit(fn -> Cache.forget() end)
    forget_channel_parameters()
    expect(Relay.KeysMock, :ping, fn -> :ok end)
    assert {:error, %Relay.Error{code: :no_active_version}} = Datasets.channel_parameters()

    assert %{"status" => "channel_parameters_missing"} =
             conn |> get("/readyz") |> json_response(503)

    load_channel_parameters()
    expect(Relay.KeysMock, :ping, fn -> :ok end)
    assert %{"status" => "ok"} = build_conn() |> get("/readyz") |> json_response(200)
  end
end
