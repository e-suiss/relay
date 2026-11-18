#!/bin/sh
# TN-63
# T-53
# T-98
# OP-84
set -eu

root="$(cd "$(dirname "$0")" && pwd)"
for program in pkcs11_port mjml_port archive_port; do
  cd "$root/$program"
  cargo build --locked --release
  cd target/release
  if command -v sha256sum >/dev/null; then
    sha256sum "$program" > "$program.sha256"
  else
    shasum -a 256 "$program" > "$program.sha256"
  fi
done
