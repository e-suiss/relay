#!/usr/bin/env sh
set -eu
if ! command -v dotnet > /dev/null 2>&1; then
  echo "dotnet is not installed, skipping sdks/dotnet"
  exit 0
fi
cd "$(dirname "$0")"
dotnet restore Esuiss.Relay.slnx --locked-mode
dotnet test Esuiss.Relay.slnx --no-restore --filter "FullyQualifiedName~LiveSmokeTests"
