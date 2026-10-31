defmodule Relay.Api do
  @moduledoc """
  The core of the HTTP API edge: the contract read from `contracts/`, the error catalog and problem documents, API versions, request schema validation, signed pagination cursors, the API rate limit tiers and idempotent request execution, and the operations of the server API, which compose the contexts for each request: sending (`Events`, `CloudEvent`, `Cancels`), queries, subscribers, workflows, type mappings and kill switches. The web layer (`RelayWeb`) turns these into plugs and responses.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Ingest,
      Relay.Tenancy,
      Relay.Tenancy.KillSwitch,
      Relay.Workflow,
      Relay.Subscribers,
      Relay.Delivery,
      Relay.Access
    ],
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
      Tenant,
      Events,
      CloudEvent,
      Views,
      Page,
      Duration,
      Subscribers,
      Workflows,
      Mappings,
      Cancels,
      Queries,
      KillSwitches
    ]
end
