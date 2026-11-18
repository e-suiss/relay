#!/usr/bin/env bash
# X-48
# X-53
set -euo pipefail

cd "$(dirname "$0")/internal/codegen"

case "$(go env GOVERSION)" in
  go1.27.3) ;;
  *)
    echo "regenerate.sh needs Go 1.27.3, found $(go env GOVERSION)" >&2
    exit 1
    ;;
esac

GOTOOLCHAIN=local go run . -contracts ../../../../contracts -out ../..
