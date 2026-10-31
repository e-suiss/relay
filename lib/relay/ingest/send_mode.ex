defmodule Relay.Ingest.SendMode do
  @moduledoc """
  The send mode of a delivery (OP-51, API-62): `live`, `shadow`, `dry_run` or `off`, resolved in a fixed order: the request's own mode (test environment only), then the tenant settings `send_mode.category.<category>.channel.<channel>`, `send_mode.channel.<channel>` and `send_mode`, then the installation default, which is `live`. `off` records the delivery as skipped with `send_mode_off`; it is not a kill switch.
  """

  @modes ~w(live shadow dry_run off)

  @type mode :: :live | :shadow | :dry_run | :off

  @doc "The settings keys that can decide the mode of a category and channel, most specific first."
  @spec keys(String.t(), String.t()) :: [String.t()]
  def keys(category, channel) do
    [
      "send_mode.category.#{category}.channel.#{channel}",
      "send_mode.channel.#{channel}",
      "send_mode"
    ]
  end

  # OP-51
  @doc "Resolves the mode of a channel from the request's mode, the tenant settings and the installation default."
  @spec resolve(String.t() | nil, %{String.t() => term()}, String.t(), String.t(), String.t()) ::
          mode()
  def resolve(requested, settings, category, channel, installation \\ "live") do
    [requested | Enum.map(keys(category, channel), &Map.get(settings, &1))]
    |> Enum.find(installation, &(&1 in @modes))
    |> cast()
  end

  defp cast("live"), do: :live
  defp cast("shadow"), do: :shadow
  defp cast("dry_run"), do: :dry_run
  defp cast("off"), do: :off
end
