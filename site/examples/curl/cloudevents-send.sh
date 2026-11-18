curl -sS --fail-with-body -X POST "$RELAY/v1/events" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop POST /v1/events)" \
  -H "Content-Type: application/cloudevents+json" \
  -d '{
    "specversion": "1.0",
    "id": "shop.public.customers:0/4821:1",
    "source": "/debezium/shop",
    "type": "com.example.shop.customer.created",
    "time": "2026-11-18T09:30:00Z",
    "datacontenttype": "application/json",
    "data": { "id": 4821, "customer_ref": "user-4821", "first_name": "Ayşe" }
  }'
