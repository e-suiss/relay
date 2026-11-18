curl --cacert "$CA" -sS --fail-with-body "$RELAY/v1/test/inbox?limit=1" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop GET /v1/test/inbox)"
