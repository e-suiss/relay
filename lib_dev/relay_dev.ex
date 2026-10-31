defmodule RelayDev do
  @moduledoc """
  Development-only tooling: repository lints, the rule catalog, benchmark gates, the local sample data and the local Access stand-in. Compiled in the dev and test environments only, never shipped in a release.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Access,
      Relay.Datasets,
      Relay.Tenancy,
      Relay.Tenancy.Provisioning,
      Relay.Workflow,
      RelayWeb
    ],
    exports: :all
end
