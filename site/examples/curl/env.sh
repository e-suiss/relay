export RELAY=http://localhost:4000
TOKEN=$(mix relay.dev.token)
export TOKEN
dpop() { mix relay.dev.proof "$1" "$RELAY$2" "$TOKEN"; }
