curl --cacert "$CA" -sS --fail-with-body -X POST "$RELAY/v1/events" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/events)" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d '{
    "workflow": "welcome",
    "to": [{ "id": "user-4821", "email": "ayse@example.com" }],
    "data": { "first_name": "Ayşe" }
  }'
