curl --cacert "$CA" -sS --fail-with-body "$RELAY/v1/subscribers/user-4821/decisions" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(dpop GET /v1/subscribers/user-4821/decisions)"
