#!/bin/sh
set -eu
cd "$(dirname "$0")"
generator="openapi-typescript@7.13.0"
npx --yes "$generator" ../contracts/openapi/server.yaml -o src/api/generated/server.ts
npx --yes "$generator" ../contracts/openapi/operator.yaml -o src/api/generated/operator.ts
