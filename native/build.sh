#!/bin/sh
# TN-63
# T-53
set -eu

cd "$(dirname "$0")/pkcs11_port"
cargo build --locked --release
cd target/release
if command -v sha256sum >/dev/null; then
  sha256sum pkcs11_port > pkcs11_port.sha256
else
  shasum -a 256 pkcs11_port > pkcs11_port.sha256
fi
