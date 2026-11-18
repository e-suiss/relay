#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
dotnet restore Esuiss.Relay.slnx --locked-mode
dotnet run --project generator/Esuiss.Relay.Generator --no-restore -- ../../contracts/openapi/server.yaml ../../contracts/errors.yaml src/Esuiss.Relay/Generated
dotnet format Esuiss.Relay.slnx --no-restore
