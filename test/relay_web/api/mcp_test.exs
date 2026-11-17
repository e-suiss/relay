defmodule RelayWeb.Api.McpTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Mcp
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @version "2026-07-28"
  @protocol_key "io.modelcontextprotocol/protocolVersion"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    client = Relay.ExternalId.encode("cli", Relay.Id.generate())
    %{scope: scope, client: client, token: Api.token(scope, ["agents"], api_client_id: client)}
  end

  defp meta(version) do
    %{
      @protocol_key => version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp headers(method, params, extra) do
    name = if is_binary(params["name"]), do: [{"mcp-name", params["name"]}], else: []
    base = [{"mcp-protocol-version", @version}, {"mcp-method", method} | name]
    Enum.reduce(extra, base, fn {key, value}, acc -> List.keystore(acc, key, 0, {key, value}) end)
  end

  defp rpc(token, method, params \\ %{}, opts \\ []) do
    params = Map.put(params, "_meta", meta(Keyword.get(opts, :version, @version)))
    body = %{"jsonrpc" => "2.0", "id" => Keyword.get(opts, :id, 1), "method" => method}
    body = Map.put(body, "params", params)
    conn = F.request(:post, "/v1/mcp", token, body, headers(method, params, opts[:headers] || []))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp call(token, tool, arguments) do
    {200, %{"result" => result}} =
      rpc(token, "tools/call", %{"name" => tool, "arguments" => arguments})

    result
  end

  defp tools(token) do
    {200, %{"result" => %{"tools" => tools} = result}} = rpc(token, "tools/list")
    {Enum.map(tools, & &1["name"]), result}
  end

  defp key, do: "mcp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  describe "AG-43 E-52 the MCP server is stateless and offers tools only" do
    test "AG-43: server/discover names the served revision and the one capability, tools", ctx do
      assert {200, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}} =
               rpc(ctx.token, "server/discover")

      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == [@version]
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "relay"
      assert Relay.Agents.protocol_versions("mcp") == Mcp.versions()
    end

    test "AG-43: a version Relay does not serve, a header that differs from the body and an unknown method are refused",
         ctx do
      assert {400, %{"error" => %{"code" => -32_022, "data" => data}}} =
               rpc(ctx.token, "tools/list", %{},
                 version: "2025-11-25",
                 headers: [{"mcp-protocol-version", "2025-11-25"}]
               )

      assert data == %{"supported" => [@version], "requested" => "2025-11-25"}

      assert {400, %{"error" => %{"code" => -32_020}}} =
               rpc(ctx.token, "tools/list", %{}, headers: [{"mcp-method", "tools/call"}])

      assert {400, %{"error" => %{"code" => -32_020}}} =
               rpc(ctx.token, "tools/call", %{"name" => "relay_send", "arguments" => %{}},
                 headers: [{"mcp-name", "relay_ack_mailbox"}]
               )

      for method <- ~w(initialize sampling/createMessage elicitation/create tasks/update) do
        assert {404, %{"error" => %{"code" => -32_601}}} = rpc(ctx.token, method)
      end
    end

    test "AG-43: no result asks the client for input; an unknown tool is an error", ctx do
      assert call(ctx.token, "relay_read_mailbox", %{})["resultType"] == "complete"

      assert {200, %{"error" => %{"code" => -32_602}}} =
               rpc(ctx.token, "tools/call", %{"name" => "relay_respond", "arguments" => %{}})
    end

    test "AG-43: an MCP task that needs input is an open waitpoint in the mapping table" do
      waitpoint = %{"object" => "waitpoint", "id" => "wp_1", "state" => "open"}
      waitpoint = Map.put(waitpoint, "kind", "question")
      result = Mcp.result(201, waitpoint)

      assert result["_meta"]["relay.esuiss/task"] ==
               %{"taskId" => "wp_1", "rule" => "state", "status" => "input_required"}

      assert result["resultType"] == "complete"
      refute Map.has_key?(result, "inputRequests")

      resolved = Mcp.result(200, %{waitpoint | "state" => "resolved"})
      assert resolved["_meta"]["relay.esuiss/task"]["status"] == "working"

      expired = Mcp.result(200, %{waitpoint | "state" => "expired"})
      task = expired["_meta"]["relay.esuiss/task"]
      assert task == %{"taskId" => "wp_1", "rule" => "owner_decides"}
    end
  end

  describe "AG-43 E-52 the tool catalogue follows the caller's scopes" do
    test "AG-43: tools/list shows only the tools the credential's scopes grant", ctx do
      mailbox = ~w(relay_read_mailbox relay_lease_mailbox relay_ack_mailbox)

      agent = Api.token(ctx.scope, ["agent:mailbox"], api_client_id: ctx.client, agent: true)
      assert {^mailbox, result} = tools(agent)
      assert result["cacheScope"] == "private"

      reader = Api.token(ctx.scope, ["read"], api_client_id: ctx.client)
      assert {~w(relay_read_waitpoint relay_list_awaiting_response), _result} = tools(reader)

      sender = Api.token(ctx.scope, ["agent:send"], api_client_id: ctx.client, agent: true)
      assert {["relay_send"], _result} = tools(sender)

      assert {all, _result} = tools(ctx.token)
      assert mailbox -- all == []
      refute "relay_send" in all
    end

    test "E-52: a call to a tool the scopes do not grant is refused by the operation's scope rule",
         ctx do
      reader = Api.token(ctx.scope, ["read"], api_client_id: ctx.client)

      arguments = %{"body" => %{"max" => 1}, "idempotency_key" => key()}
      result = call(reader, "relay_lease_mailbox", arguments)

      assert result["isError"] == true
      assert result["structuredContent"]["code"] == "auth_insufficient_scope"
      assert result["structuredContent"]["status"] == 403
    end

    test "E-52: a tool call is the HTTP operation: the same answer, schema and idempotency rule",
         ctx do
      over_http = F.body(F.request(:get, "/v1/mailbox/records", ctx.token), 200)
      over_mcp = call(ctx.token, "relay_read_mailbox", %{})

      assert over_mcp["isError"] == false
      assert over_mcp["structuredContent"] == over_http
      assert Jason.decode!(hd(over_mcp["content"])["text"]) == over_http

      missing = call(ctx.token, "relay_lease_mailbox", %{"body" => %{"max" => 1}})
      assert missing["isError"] == true
      assert missing["structuredContent"]["code"] == "idempotency_key_missing"

      short_key = %{"body" => %{"max" => 1}, "idempotency_key" => "x"}
      short = call(ctx.token, "relay_lease_mailbox", short_key)

      assert short["structuredContent"]["code"] == "idempotency_key_invalid"

      invalid = call(ctx.token, "relay_ack_mailbox", %{"body" => %{}, "idempotency_key" => key()})

      assert invalid["isError"] == true
      assert invalid["structuredContent"]["status"] == 422

      arguments = %{"body" => %{"max" => 1}, "idempotency_key" => key()}
      first = call(ctx.token, "relay_lease_mailbox", arguments)
      assert first["isError"] == false
      assert first["structuredContent"]["object"] == "mailbox_lease"
      again = call(ctx.token, "relay_lease_mailbox", arguments)
      assert again["structuredContent"] == first["structuredContent"]
    end
  end

  describe "AG-45 E-54 a protocol cannot pass the approval gate" do
    test "AG-45: the catalogue has no tool that answers, completes or cancels a waitpoint" do
      operations = Enum.map(Mcp.tools(), & &1.operation)

      assert operations ==
               ~w(createEvent createWaitpoint getWaitpoint listWaitpoints listMailboxRecords
                  leaseMailboxRecords ackMailboxRecords addTopicSubscriptions)

      for tool <- Mcp.tools() do
        refute tool.name =~ ~r/respond|answer|approv|decid|complete|resolve|cancel/
        assert tool.descriptor["inputSchema"]["additionalProperties"] == false
      end
    end

    test "E-54: every tool is an operation of the contract and inherits its scopes", ctx do
      for tool <- Mcp.tools() do
        operation = Relay.Api.Contract.operation!(tool.operation)
        refute operation.scopes == []
        assert Mcp.granted?(tool, [hd(operation.scopes)])
        refute Mcp.granted?(tool, ["presence:read"])
      end

      watcher = Api.token(ctx.scope, ["presence:read"], api_client_id: ctx.client, agent: true)
      assert {[], _result} = tools(watcher)
    end
  end
end
