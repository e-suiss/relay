defmodule Relay.CLI.Rollout do
  @moduledoc """
  `relay rollout`: the staged rollout of the environment through the API (OP-53, OP-95).

  * `get` (`getRollout`): the configuration in force.
  * `emergency-stop` (`stopRollout`): `--reason`; one command routes every request of the environment to the system being replaced and opens an incident record.
  * `release` (`releaseRollout`): `--reason`; routing follows the configuration again.

  In `live` every write needs confirmation.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Confirm
  alias Relay.CLI.Failure

  @path "/v1/rollout"

  # OP-53
  # OP-95
  @impl Relay.CLI.Command
  def run(ctx, %Args{sub: "get"}) do
    case Client.call(ctx, ctx.config.environment, :get, @path) do
      {:ok, %{body: %{} = rollout}} -> {:ok, rollout, [line(rollout)]}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  def run(ctx, %Args{sub: "emergency-stop", opts: opts}) do
    with {:ok, reason} <- reason(opts) do
      write(ctx, "rollout emergency-stop routes everything away", "/emergency_stop", reason)
    end
  end

  def run(ctx, %Args{sub: "release", opts: opts}) do
    with {:ok, reason} <- reason(opts) do
      write(ctx, "rollout release lifts the emergency stop", "/emergency_stop/release", reason)
    end
  end

  defp write(ctx, action, suffix, reason) do
    environment = ctx.config.environment
    body = %{"reason" => reason}

    with :ok <- Confirm.live(ctx, environment, action),
         {:ok, response} <- Client.call(ctx, environment, :post, @path <> suffix, json: body) do
      {:ok, response.body, [line(response.body)]}
    end
  end

  defp reason(opts) do
    case opts[:reason] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, Failure.new(:usage, "usage_error", "--reason is required")}
    end
  end

  defp line(%{"object" => "rollout"} = rollout) do
    stop = if rollout["emergency_stop"], do: "stopped", else: "running"
    shares = Enum.map_join(rollout["basis_points"] || %{}, " ", fn {k, v} -> "#{k}=#{v}" end)
    String.trim("rollout #{stop} generation=#{rollout["generation"]} #{shares}")
  end

  defp line(other), do: inspect(other)
end
