defmodule RelayWeb.ConsoleControllerTest do
  use RelayWeb.ConnCase, async: false

  @index ~s(<!doctype html><html lang="en"><body><div id="root"></div></body></html>)

  setup do
    previous = Application.get_env(:relay, RelayWeb.Console)
    root = Path.join(System.tmp_dir!(), "relay-console-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:relay, RelayWeb.Console, previous),
        else: Application.delete_env(:relay, RelayWeb.Console)
    end)

    Application.put_env(:relay, RelayWeb.Console, root: root)
    %{root: root}
  end

  test "X-47: every console path answers the application under a strict policy", %{
    conn: conn,
    root: root
  } do
    File.write!(Path.join(root, "index.html"), @index)

    for path <- ["/console", "/console/", "/console/why", "/console/workflows/welcome"] do
      conn = get(conn, path)

      assert conn.status == 200
      assert conn.resp_body == @index
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy == RelayWeb.ConsoleController.policy()
      assert policy =~ "default-src 'none'"
      assert policy =~ "script-src 'self'"
      assert policy =~ "connect-src 'self'"
      assert policy =~ "frame-ancestors 'none'"
      refute policy =~ "unsafe-inline"
      refute policy =~ "unsafe-eval"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
    end
  end

  test "X-47: a missing asset is not answered with the application", %{conn: conn, root: root} do
    File.write!(Path.join(root, "index.html"), @index)

    assert conn |> get("/console/assets/missing.js") |> response(404) == ""
  end

  test "X-47: a node without a built console answers not found", %{conn: conn} do
    assert conn |> get("/console/why") |> response(404) == ""
  end
end
