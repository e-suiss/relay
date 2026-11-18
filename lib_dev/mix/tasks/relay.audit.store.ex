defmodule Mix.Tasks.Relay.Audit.Store do
  @shortdoc "Creates the object-locked audit checkpoint and archive buckets on the local MinIO"
  @moduledoc "Runs `RelayDev.ObjectStore.setup/2` against the MinIO service of `deploy/compose.yaml` for the audit checkpoint bucket and the cold archive bucket."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:req)

    for {name, opts} <- [
          {"audit checkpoint", RelayDev.ObjectStore.local()},
          {"archive", RelayDev.ObjectStore.local(bucket: "relay-archive")}
        ] do
      case RelayDev.ObjectStore.setup(opts) do
        :ok -> Mix.shell().info("#{name} bucket ready")
        {:error, reason} -> Mix.raise("#{name} bucket setup failed: #{inspect(reason)}")
      end
    end
  end
end
