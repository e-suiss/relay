defmodule Relay.ObjectStore do
  @moduledoc """
  Write-once access to S3-compatible object stores with object lock (WORM): the transport shared by the audit checkpoint target and the cold archive. Each user keeps its own bucket and credentials.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: [S3]
end
