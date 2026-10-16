defmodule Relay.Platform.Maintenance do
  @moduledoc """
  Cross-tenant maintenance: the partition and integrity singleton tasks and the escape hatch through which every cross-tenant maintenance query runs (`Relay.Platform.Maintenance.EscapeHatch`).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform.MaintRepo, Relay.Platform.Leadership],
    exports: [EscapeHatch]
end
