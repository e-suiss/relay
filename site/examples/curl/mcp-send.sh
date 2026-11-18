curl --cacert "$CA" -sS --fail-with-body -X POST "$RELAY/v1/mcp" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/mcp)" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: relay_send" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "relay_send",
      "arguments": {
        "idempotency_key": "agent-run:7f3a:welcome:user-4821",
        "body": {
          "workflow": "welcome",
          "to": ["user-4821"],
          "data": { "first_name": "Ayşe" }
        }
      },
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": { "name": "my-agent", "version": "1.0.0" },
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
