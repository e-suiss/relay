export RELAY=https://localhost:4443
export CA="$PWD/deploy/tls/root.crt"
export NODE_EXTRA_CA_CERTS="$CA"
TOKEN=$(mix relay.dev.token)
export TOKEN
dpop() { mix relay.dev.proof "$1" "$RELAY$2" "$TOKEN"; }
