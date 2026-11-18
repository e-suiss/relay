#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
venv="$(mktemp -d)"
trap 'rm -rf "$venv"' EXIT

python3 -m venv "$venv"
"$venv/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes --no-deps -r "$here/requirements-dev.lock"
"$venv/bin/python" "$here/codegen/generate.py"
