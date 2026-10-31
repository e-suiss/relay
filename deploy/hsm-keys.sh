#!/bin/sh
# TN-63
# TN-66 (1)
# TN-67 (1)
# TN-67 (4)
# API-56
# OP-63
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: deploy/hsm-keys.sh

Creates the stage-1 keys in a PKCS#11 token with pkcs11-tool. Keys that already
exist under their label are left untouched, so the script can be rerun.

  audit-checkpoint   Ed25519 key pair that signs audit checkpoints
  KEK                AES-256 key that wraps tenant data keys
  fingerprint        256-bit generic secret for the HMAC-SHA256 secret fingerprints
  cursor             256-bit generic secret for the HMAC-SHA256 pagination cursor tags
  blind index        256-bit generic secret for HMAC-SHA256 blind indexes, only
                     when KEY_STORE_BLIND_INDEX_LABEL is set; production
                     blind index keys are per tenant and generated in the token
                     when the tenant is created

Environment:
  PKCS11_MODULE                 path of the PKCS#11 provider library
  PKCS11_TOKEN                  token label
  PKCS11_PIN_FILE               file holding the user PIN
  KEY_STORE_CHECKPOINT_LABEL    default: audit-checkpoint
  KEY_STORE_KEK_LABEL           label of the KEK (required)
  KEY_STORE_FINGERPRINT_LABEL   label of the secret fingerprint key (required)
  KEY_STORE_CURSOR_LABEL        label of the pagination cursor key (required)
  KEY_STORE_BLIND_INDEX_LABEL   label of a blind index key (optional, local development)
USAGE
  exit 2
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

: "${PKCS11_MODULE:?PKCS11_MODULE is required}"
: "${PKCS11_TOKEN:?PKCS11_TOKEN is required}"
: "${PKCS11_PIN_FILE:?PKCS11_PIN_FILE is required}"
: "${KEY_STORE_KEK_LABEL:?KEY_STORE_KEK_LABEL is required}"
: "${KEY_STORE_FINGERPRINT_LABEL:?KEY_STORE_FINGERPRINT_LABEL is required}"
: "${KEY_STORE_CURSOR_LABEL:?KEY_STORE_CURSOR_LABEL is required}"
checkpoint="${KEY_STORE_CHECKPOINT_LABEL:-audit-checkpoint}"

command -v pkcs11-tool >/dev/null || { echo "pkcs11-tool not found; install OpenSC" >&2; exit 1; }
[ -r "$PKCS11_PIN_FILE" ] || { echo "cannot read $PKCS11_PIN_FILE" >&2; exit 1; }

HSM_KEYS_PIN="$(tr -d '\n' <"$PKCS11_PIN_FILE")"
export HSM_KEYS_PIN

tool() {
  pkcs11-tool --module "$PKCS11_MODULE" --token-label "$PKCS11_TOKEN" --login --pin env:HSM_KEYS_PIN "$@"
}

exists() {
  tool --list-objects --type "$1" --label "$2" 2>/dev/null | grep -q "label: *$2\$"
}

create() {
  type="$1"
  label="$2"
  shift 2
  if exists "$type" "$label"; then
    echo "hsm-keys: $label exists"
  else
    tool "$@" --label "$label" >/dev/null
    exists "$type" "$label" || { echo "hsm-keys: $label was not created" >&2; exit 1; }
    echo "hsm-keys: $label created"
  fi
}

create privkey "$checkpoint" --keypairgen --key-type EC:edwards25519
create secrkey "$KEY_STORE_KEK_LABEL" --keygen --key-type AES:32 --sensitive
create secrkey "$KEY_STORE_FINGERPRINT_LABEL" --keygen --key-type GENERIC:32 --sensitive --usage-sign
create secrkey "$KEY_STORE_CURSOR_LABEL" --keygen --key-type GENERIC:32 --sensitive --usage-sign
if [ -n "${KEY_STORE_BLIND_INDEX_LABEL:-}" ]; then
  create secrkey "$KEY_STORE_BLIND_INDEX_LABEL" --keygen --key-type GENERIC:32 --sensitive --usage-sign
fi
