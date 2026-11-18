KEY=$(uuidgen)
send() {
  curl --cacert "$CA" -sS --fail-with-body -D - -o /dev/null -X POST "$RELAY/v1/events" \
    -H "Authorization: DPoP $TOKEN" \
    -H "DPoP: $(dpop POST /v1/events)" \
    -H "Idempotency-Key: $KEY" \
    -H "Content-Type: application/json" \
    -d '{"workflow": "welcome", "to": ["user-4821"], "data": {"first_name": "Ayşe"}}'
}
send
send
