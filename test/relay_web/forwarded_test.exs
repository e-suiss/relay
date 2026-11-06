defmodule RelayWeb.ForwardedTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest

  alias RelayTest.Api
  alias RelayWeb.Api.Response

  @endpoint RelayWeb.Endpoint
  @path "/.well-known/relay-configuration"

  setup do
    previous = Application.get_env(:relay, RelayWeb.Api, [])
    on_exit(fn -> Application.put_env(:relay, RelayWeb.Api, previous) end)
    proxy = Api.ip()
    ranges = [to_string(:inet.ntoa(proxy)) <> "/32"]
    Application.put_env(:relay, RelayWeb.Api, Keyword.put(previous, :trusted_proxies, ranges))
    %{proxy: proxy}
  end

  defp request(peer, headers) do
    conn = %{build_conn() | remote_ip: peer}

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> Plug.Conn.put_req_header(acc, name, value) end)
    |> get(@path)
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["code"]

  describe "E-91 trusted proxies" do
    test "E-91: behind a trusted proxy that terminated TLS the API answers with the configured issuer",
         ctx do
      headers = [
        {"x-forwarded-proto", "https"},
        {"x-forwarded-host", "relay.proxy.test"},
        {"x-forwarded-for", "203.0.113.9"}
      ]

      conn = request(ctx.proxy, headers)
      assert conn.status == 200
      Api.assert_contract(conn)
      document = Jason.decode!(conn.resp_body)
      assert document["issuer"] == String.trim_trailing(Response.base_url(), "/")
    end

    test "E-91: plain HTTP is refused, whether direct or forwarded as such", ctx do
      for conn <- [
            request(ctx.proxy, []),
            request(ctx.proxy, [{"x-forwarded-proto", "http"}]),
            request(ctx.proxy, [{"x-forwarded-proto", "https, http"}])
          ] do
        assert conn.status == 400
        assert code(conn) == "malformed_request"
      end
    end

    test "E-91: forwarded headers from a peer outside the list are ignored" do
      conn = request(Api.ip(), [{"x-forwarded-proto", "https"}])
      assert conn.status == 400
      assert code(conn) == "malformed_request"
    end
  end
end
