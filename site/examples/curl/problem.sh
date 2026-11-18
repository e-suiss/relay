curl --cacert "$CA" -sS -X POST "$RELAY/v1/events" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/events)" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d '{"workflow": "welcome", "to": ["user-4821"], "data": {"first_name": "Ayşe"}, "colour": "blue"}'
