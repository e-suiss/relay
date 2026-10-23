defmodule Mix.Tasks.Relay.Audit.Store do
  @shortdoc "Creates the object-locked audit checkpoint bucket on the local MinIO"
  @moduledoc "Runs `RelayDev.ObjectStore.setup/2` against the MinIO service of `deploy/compose.yaml`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:req)

    case RelayDev.ObjectStore.setup() do
      :ok -> Mix.shell().info("audit checkpoint bucket ready")
      {:error, reason} -> Mix.raise("audit checkpoint bucket setup failed: #{inspect(reason)}")
    end
  end
end
