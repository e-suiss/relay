defmodule Relay.CLI.Feed do
  @moduledoc """
  Polling of new notifications for `logs --follow` and `listen`. Each poll reads `GET /v1/notifications` (operation `listNotifications`) with `created_after` set to the newest creation time seen so far, the start of the command at first, follows every page and hands over the notifications not seen before, oldest first. A connection failure is reported and the next poll tries again; any other failure ends the command.
  """

  alias Relay.CLI.Client
  alias Relay.CLI.Context
  alias Relay.CLI.Failure
  alias Relay.CLI.Output

  @enforce_keys [:watermark]
  defstruct [:watermark, seen: %{}]

  @type summary :: %{polls: non_neg_integer(), notifications: non_neg_integer()}
  @type t :: %__MODULE__{watermark: DateTime.t(), seen: %{optional(String.t()) => DateTime.t()}}

  @doc "A feed of the notifications created from `since` on."
  @spec new(DateTime.t()) :: t()
  def new(%DateTime{} = since), do: %__MODULE__{watermark: %{since | microsecond: {0, 0}}}

  @doc "Marks notifications as seen, so later polls do not hand them over again."
  @spec mark(t(), [map()]) :: t()
  def mark(%__MODULE__{} = feed, notifications) do
    Enum.reduce(timed(notifications), feed, fn {notification, at}, acc ->
      %{acc | seen: Map.put(acc.seen, notification["id"], at)}
    end)
  end

  # X-33
  # API-56
  @doc "Reads the notifications created since the last poll that were not seen yet, oldest first."
  @spec poll(Context.t(), keyword(), t()) :: {:ok, [map()], t()} | {:error, Failure.t()}
  def poll(%Context{} = ctx, filters, %__MODULE__{} = feed) do
    params = [{:created_after, DateTime.to_iso8601(feed.watermark)} | filters]

    case Client.list_all(ctx, ctx.config.environment, "/v1/notifications", params) do
      {:ok, notifications} ->
        fresh =
          notifications
          |> timed()
          |> Enum.reject(&seen?(feed, &1))
          |> Enum.sort_by(fn {_notification, at} -> at end, DateTime)

        {:ok, Enum.map(fresh, &elem(&1, 0)), advance(feed, fresh)}

      {:error, _failure} = error ->
        error
    end
  end

  # X-33
  @doc """
  Polls every `interval_ms` and calls `handle` with each batch of new notifications, until the run's `:max_polls` is reached; without it the command runs until it is stopped. Returns the number of polls and of notifications handed over.
  """
  @spec follow(Context.t(), keyword(), pos_integer(), t(), ([map()] -> term())) ::
          {:ok, summary()} | {:error, Failure.t()}
  def follow(%Context{} = ctx, filters, interval_ms, %__MODULE__{} = feed, handle) do
    loop(ctx, %{filters: filters, interval_ms: interval_ms, handle: handle}, feed, {0, 0})
  end

  defp loop(ctx, spec, feed, {polls, count}) do
    case poll(ctx, spec.filters, feed) do
      {:ok, fresh, feed} ->
        spec.handle.(fresh)
        next(ctx, spec, feed, {polls + 1, count + length(fresh)})

      {:error, %Failure{kind: :unavailable} = failure} ->
        Output.warn(ctx, failure.message)
        next(ctx, spec, feed, {polls + 1, count})

      {:error, _failure} = error ->
        error
    end
  end

  defp next(ctx, spec, feed, {polls, count}) do
    if ctx.max_polls != nil and polls >= ctx.max_polls do
      {:ok, %{polls: polls, notifications: count}}
    else
      ctx.sleep.(spec.interval_ms)
      loop(ctx, spec, feed, {polls, count})
    end
  end

  defp seen?(feed, {notification, _at}), do: Map.has_key?(feed.seen, notification["id"])

  defp advance(feed, fresh) do
    seen = Enum.reduce(fresh, feed.seen, fn {n, at}, acc -> Map.put(acc, n["id"], at) end)
    watermark = Enum.max([feed.watermark | Map.values(seen)], DateTime)
    pruned = Map.filter(seen, fn {_id, at} -> DateTime.compare(at, watermark) != :lt end)
    %{feed | watermark: watermark, seen: pruned}
  end

  defp timed(notifications) do
    for %{"id" => id, "created_at" => created_at} = notification <- notifications,
        is_binary(id) and is_binary(created_at),
        {:ok, at, _offset} <- [DateTime.from_iso8601(created_at)],
        do: {notification, at}
  end
end
