defmodule Relay.Channels.Push.H2Test do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.H2
  alias RelayTest.H2Server

  defp ok(_request), do: {200, [{"apns-id", "a"}], ""}

  defp request(path \\ "/3/device/abc"),
    do: %{method: "POST", path: path, headers: [{"content-type", "application/json"}], body: "{}"}

  defp tenant, do: Relay.Id.generate()

  defp send_async(tenant, key, port, opts \\ [], timeout \\ 5_000) do
    Task.async(fn ->
      H2.request(tenant, key, {:http, "localhost", port}, nil, request(), timeout, opts)
    end)
  end

  describe "CH-24 T-37 admission control" do
    test "CH-24, T-37: a request is answered on a lazily opened connection" do
      {:ok, port} = H2Server.start(&ok/1)
      tenant = tenant()

      assert H2.whereis(tenant, :k) == nil

      assert {:ok, %{status: 200, headers: headers}} =
               H2.request(tenant, :k, {:http, "localhost", port}, nil, request(), 5_000)

      assert {"apns-id", "a"} in headers
      assert is_pid(H2.whereis(tenant, :k))
      assert_receive {:h2_request, _conn, 1, %{headers: %{":path" => "/3/device/abc"}}}
    end

    test "CH-24: a cold connection carries one stream until SETTINGS arrive, then up to the server's limit" do
      opts = [settings_delay_ms: 400, max_concurrent_streams: 2]
      {:ok, port} = H2Server.start(fn _request -> :hold end, opts)
      tenant = tenant()

      tasks = for _ <- 1..3, do: send_async(tenant, :cold, port)

      assert_receive {:h2_request, conn, first, _request}, 2_000
      refute_receive {:h2_request, _conn, _id, _request}, 200

      assert_receive {:h2_request, ^conn, second, _request}, 2_000
      refute_receive {:h2_request, _conn, _id, _request}, 200

      H2Server.release(conn, first, {200, [], ""})
      assert_receive {:h2_request, ^conn, third, _request}, 2_000

      H2Server.release(conn, second, {200, [], ""})
      H2Server.release(conn, third, {200, [], ""})

      for task <- tasks, do: assert({:ok, %{status: 200}} = Task.await(task))
    end

    test "CH-24: a request past the bounded queue is refused as too_many_concurrent_requests" do
      {:ok, port} = H2Server.start(fn _request -> :hold end, max_concurrent_streams: 1)
      tenant = tenant()
      opts = [max_queue: 1]

      held = send_async(tenant, :full, port, opts)
      assert_receive {:h2_request, conn, id, _request}, 2_000
      queued = send_async(tenant, :full, port, opts)
      Process.sleep(100)

      assert H2.request(tenant, :full, {:http, "localhost", port}, nil, request(), 1_000, opts) ==
               {:not_sent, "too_many_concurrent_requests"}

      H2Server.release(conn, id, {200, [], ""})
      assert {:ok, %{status: 200}} = Task.await(held)
      assert_receive {:h2_request, ^conn, next, _request}, 2_000
      H2Server.release(conn, next, {200, [], ""})
      assert {:ok, %{status: 200}} = Task.await(queued)
    end

    test "T-28: an answer that never comes is uncertain and a queued request past its deadline was never sent" do
      {:ok, port} = H2Server.start(fn _request -> :hold end, max_concurrent_streams: 1)
      tenant = tenant()

      held = send_async(tenant, :slow, port, [], 300)
      assert_receive {:h2_request, _conn, _id, _request}, 2_000
      waiting = send_async(tenant, :slow, port, [], 150)

      assert Task.await(waiting) == {:not_sent, "queue_timeout"}
      assert Task.await(held) == {:uncertain, "timeout"}
    end
  end

  describe "INV-40 connection per tenant and key" do
    test "INV-40: different tenants never share a connection, one tenant's key reuses its own" do
      {:ok, port} = H2Server.start(&ok/1)
      a = tenant()
      b = tenant()
      origin = {:http, "localhost", port}

      assert {:ok, _} = H2.request(a, :same, origin, nil, request(), 5_000)
      assert_receive {:h2_request, conn_a, _id, _request}
      assert {:ok, _} = H2.request(a, :same, origin, nil, request(), 5_000)
      assert_receive {:h2_request, ^conn_a, _id, _request}
      assert {:ok, _} = H2.request(b, :same, origin, nil, request(), 5_000)
      assert_receive {:h2_request, conn_b, _id, _request}

      assert conn_a != conn_b
      assert H2.whereis(a, :same) != H2.whereis(b, :same)
    end

    test "INV-40: a connection refuses a request for another key" do
      {:ok, port} = H2Server.start(&ok/1)
      tenant = tenant()
      origin = {:http, "localhost", port}
      assert {:ok, _} = H2.request(tenant, :own, origin, nil, request(), 5_000)

      pid = H2.whereis(tenant, :own)

      assert GenServer.call(pid, {:request, :other, nil, request(), 0}) ==
               {:not_sent, "connection_key_mismatch"}
    end
  end

  describe "CH-24 connection life cycle" do
    test "CH-24: after a GOAWAY open streams finish and new requests go on a fresh connection" do
      {:ok, port} = H2Server.start(fn _request -> :hold end)
      tenant = tenant()

      first = send_async(tenant, :goaway, port)
      assert_receive {:h2_request, old, id, _request}, 2_000
      H2Server.goaway(old, id)
      Process.sleep(100)

      second = send_async(tenant, :goaway, port)
      assert_receive {:h2_request, new, new_id, _request}, 2_000
      assert new != old

      H2Server.release(old, id, {200, [], ""})
      H2Server.release(new, new_id, {201, [], ""})
      assert {:ok, %{status: 200}} = Task.await(first)
      assert {:ok, %{status: 201}} = Task.await(second)
    end

    test "CH-24: an idle connection stops and the next request opens a new one" do
      {:ok, port} = H2Server.start(&ok/1)
      tenant = tenant()
      opts = [idle_ms: 100]
      origin = {:http, "localhost", port}

      assert {:ok, _} = H2.request(tenant, :idle, origin, nil, request(), 5_000, opts)
      pid = H2.whereis(tenant, :idle)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert {:ok, _} = H2.request(tenant, :idle, origin, nil, request(), 5_000, opts)
      assert H2.whereis(tenant, :idle) not in [nil, pid]
    end

    test "CH-24: a missing pong closes the connection" do
      {:ok, port} = H2Server.start(&ok/1, pong: false)
      tenant = tenant()
      opts = [ping_ms: 50, ping_timeout_ms: 50]
      origin = {:http, "localhost", port}

      assert {:ok, _} = H2.request(tenant, :ping, origin, nil, request(), 5_000, opts)
      assert_receive {:h2_request, first, _id, _request}
      Process.sleep(300)

      assert {:ok, _} = H2.request(tenant, :ping, origin, nil, request(), 5_000, opts)
      assert_receive {:h2_request, second, _id, _request}
      assert first != second
    end

    test "CH-24: a connection that cannot open answers never sent" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      assert H2.request(tenant(), :closed, {:http, "localhost", port}, nil, request(), 1_000) ==
               {:not_sent, "connect_failed"}
    end
  end
end
