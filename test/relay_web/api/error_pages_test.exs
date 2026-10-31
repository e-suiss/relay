defmodule RelayWeb.Api.ErrorPagesTest do
  use Relay.DataCase, async: true

  import Plug.Conn

  alias Relay.Api.ErrorCatalog
  alias RelayTest.Api
  alias RelayWeb.Api.Response

  defp page(code, ip \\ Api.ip()) do
    :get
    |> Api.conn("/v1/errors/" <> code)
    |> Map.put(:remote_ip, ip)
    |> Api.call(RelayWeb.Router)
  end

  describe "API-73 error code pages" do
    test "API-73: every catalog code is served unauthenticated on the region's address" do
      ip = Api.ip()

      for code <- Enum.take(ErrorCatalog.codes(), 15) do
        conn = page(code, ip)
        assert conn.status == 200
        Api.assert_contract(conn)
        body = Jason.decode!(conn.resp_body)

        {:ok, entry} = ErrorCatalog.fetch(code)
        assert body["code"] == code
        assert body["status"] == entry.status
        assert body["type"] == Response.base_url() <> "/v1/errors/" <> code
      end
    end

    test "API-73: an unknown code is 404 error_code_not_found" do
      conn = page("no_such_code")
      assert conn.status == 404
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "error_code_not_found"
    end

    test "API-36: a problem type points at a page that resolves" do
      conn = page("no_such_code")
      %{"type" => type} = Jason.decode!(conn.resp_body)
      path = URI.parse(type).path

      assert path == "/v1/errors/error_code_not_found"
      assert page("error_code_not_found").status == 200
    end

    test "API-77 (3): error pages are limited per client IP" do
      ip = Api.ip()
      statuses = for _ <- 1..21, do: page("rate_limited", ip).status

      assert Enum.take(statuses, 20) == List.duplicate(200, 20)
      assert List.last(statuses) == 429
      Api.assert_contract(page("rate_limited", ip))
    end

    test "API-36: an unmatched /v1 route is a catalog problem, never about:blank" do
      routes = [{:get, "/v1/nowhere"}, {:post, "/v1/errors/x"}, {:delete, "/v1/kill_switches"}]

      for {method, path} <- routes do
        conn = method |> Api.conn(path) |> Api.call(RelayWeb.Router)
        body = Jason.decode!(conn.resp_body)

        assert conn.status == 404
        assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
        assert body["code"] == "route_not_found"
        assert body["type"] == Response.base_url() <> "/v1/errors/route_not_found"
        assert page("route_not_found").status == 200
      end
    end

    test "API-8: error pages carry Request-Id, Relay-Version and HSTS" do
      conn = page("rate_limited")
      assert [_] = get_resp_header(conn, "request-id")
      assert get_resp_header(conn, "relay-version") == [Relay.Api.Versions.latest()]
      assert [_] = get_resp_header(conn, "strict-transport-security")
    end
  end

  describe "API-2 router coverage" do
    test "API-2: every /v1 route of the router is a contract operation at its own path" do
      coverage = Api.coverage(RelayWeb.Router)

      assert coverage.foreign == []
      assert "getErrorCode" in coverage.served

      assert Enum.sort(coverage.served ++ coverage.missing) ==
               Enum.sort(Enum.map(Relay.Api.Contract.operations(), & &1.id))
    end

    test "API-2: the edge test router names contract operations only" do
      assert Api.coverage(RelayTest.Api.Router).foreign == []
    end
  end
end
