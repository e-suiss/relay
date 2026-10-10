defmodule Relay.Ingest do
  @moduledoc """
  Event intake, idempotency and deduplication. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
