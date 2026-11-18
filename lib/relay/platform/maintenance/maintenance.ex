defmodule Relay.Platform.Maintenance do
  @moduledoc """
  Cross-tenant maintenance: the partition, archive and integrity singleton tasks, the escape hatch through which every cross-tenant maintenance query runs (`Relay.Platform.Maintenance.EscapeHatch`) and the restore of archived partitions (`Relay.Platform.Maintenance.Restore`).
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform.MaintRepo,
      Relay.Platform.ArchiveRepo,
      Relay.Platform.Leadership,
      Relay.ObjectStore,
      Relay.Parquet
    ],
    exports: [EscapeHatch, Restore]
end
