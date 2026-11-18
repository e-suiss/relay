curl -sS --fail-with-body -X POST "$RELAY/v1/mcp" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/mcp)" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/list" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list",
    "params": {
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": { "name": "my-agent", "version": "1.0.0" },
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
