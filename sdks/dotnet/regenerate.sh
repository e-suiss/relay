#!/usr/bin/env sh
set -eu
if ! command -v dotnet > /dev/null 2>&1; then
  echo "dotnet is not installed, skipping sdks/dotnet"
  exit 0
fi
cd "$(dirname "$0")"
dotnet restore Esuiss.Relay.slnx --locked-mode
dotnet run --project generator/Esuiss.Relay.Generator --no-restore -- ../../contracts/openapi/server.yaml ../../contracts/errors.yaml src/Esuiss.Relay/Generated
dotnet format Esuiss.Relay.slnx --no-restore
