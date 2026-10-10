defmodule RelayDev do
  @moduledoc """
  Development-only tooling: repository lints, the rule catalog and benchmark gates. Compiled in the dev and test environments only, never shipped in a release.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: :all
end
