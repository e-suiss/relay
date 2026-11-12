defmodule RelayWeb.EndpointTest do
  use RelayWeb.ConnCase, async: true

  test "TN-61: security.txt is published with RFC 9116 fields", %{conn: conn} do
    conn = get(conn, "/.well-known/security.txt")
    body = response(conn, 200)

    assert body =~ ~r/^Contact: https:\/\//m
    assert [_, expires] = Regex.run(~r/^Expires: (.+)$/m, body)
    {:ok, expires_at, _} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires_at, Relay.Clock.utc_now(), :day) in 1..366
  end

  test "IN-54: no socket turns the origin check off and the realtime socket checks its tenant allow-list" do
    sockets = RelayWeb.Endpoint.__sockets__()
    allow_list = {RelayWeb.Realtime.Origin, :record, []}

    for {_path, _module, opts} <- sockets, websocket = opts[:websocket], is_list(websocket) do
      assert Keyword.get(websocket, :check_origin, true) in [true, allow_list]
    end

    assert {_path, _module, opts} = Enum.find(sockets, &(elem(&1, 0) == "/v1/realtime"))
    assert opts[:websocket][:check_origin] == allow_list
  end

  test "T-63: liveness answers without dependencies", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/livez") |> json_response(200)
  end

  test "T-63: every response carries Request-Id and Correlation-Id", %{conn: conn} do
    conn = get(conn, "/livez")
    assert [_] = get_resp_header(conn, "request-id")
    assert ["cor_" <> _] = get_resp_header(conn, "correlation-id")
  end

  test "T-63: a well-formed incoming correlation id is kept", %{conn: conn} do
    conn = conn |> put_req_header("correlation-id", "abc-123") |> get("/livez")
    assert get_resp_header(conn, "correlation-id") == ["abc-123"]
  end

  test "T-63: a malformed incoming correlation id is replaced", %{conn: conn} do
    conn = conn |> put_req_header("correlation-id", "bad id\n") |> get("/livez")
    assert ["cor_" <> _] = get_resp_header(conn, "correlation-id")
  end
end
