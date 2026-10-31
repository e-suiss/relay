defmodule Relay.Api do
  @moduledoc """
  The core of the HTTP API edge: the contract read from `contracts/`, the error catalog and problem documents, API versions, request schema validation, signed pagination cursors, the API rate limit tiers and idempotent request execution. The web layer (`RelayWeb`) turns these into plugs and responses.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform, Relay.Ingest, Relay.Tenancy],
    exports: [
      Contract,
      ErrorCatalog,
      ErrorMap,
      Problem,
      Versions,
      Versions.Converter,
      Schema,
      Cursor,
      Pagination,
      RateLimit,
      Idempotency,
      Tenant
    ]
end
