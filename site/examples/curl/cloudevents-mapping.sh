curl -sS --fail-with-body -X POST "$RELAY/v1/event_type_mappings" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/event_type_mappings)" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "com.example.shop.customer.created",
    "source": "/debezium/shop",
    "workflow": "welcome",
    "to_pointer": "/customer_ref",
    "data_fields": ["/first_name"]
  }'
