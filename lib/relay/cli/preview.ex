defmodule Relay.CLI.Preview do
  @moduledoc """
  `relay preview <workflow>`: runs an event with local data as a dry run, `POST /v1/events` with `send_mode: dry_run` (operation `createEvent`). Relay validates the data against the published workflow version and runs its decisions without opening deliveries. A per-request send mode exists only in the `test` environment, so a `live` client is refused before anything is sent.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Failure
  alias Relay.CLI.Trigger

  # X-33
  # API-62
  @impl Relay.CLI.Command
  def run(ctx, %Args{} = args) do
    with :ok <- test_only(ctx.config.environment),
         {:ok, event} <- Trigger.event(args),
         dry_run = Map.put(event, "send_mode", "dry_run"),
         {:ok, response} <- Client.call(ctx, :test, :post, "/v1/events", json: dry_run) do
      {:ok, response.body, Trigger.accepted_lines("dry run of", response.body)}
    end
  end

  defp test_only(:test), do: :ok

  defp test_only(:live) do
    message = "preview runs only with a test API client; a live client cannot choose a send mode"
    {:error, Failure.new(:auth, "preview_requires_test", message)}
  end
end
