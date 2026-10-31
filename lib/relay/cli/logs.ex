defmodule Relay.CLI.Logs do
  @moduledoc """
  `relay logs`: the activity and delivery log of the environment. It shows the newest page of notifications (`GET /v1/notifications`, operation `listNotifications`) with their delivery counts, filtered by `--workflow`, `--subscriber` and `--status`; `--deliveries` adds each notification's deliveries (`listNotificationDeliveries`). `--follow` then keeps printing notifications created after the command started, polling every `--interval` seconds.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Failure
  alias Relay.CLI.Feed
  alias Relay.CLI.Output

  @counts ~w(queued sent delivered unknown_pending unknown failed skipped expired cancelled)

  # X-33
  @impl Relay.CLI.Command
  def run(ctx, %Args{opts: opts}) do
    since = ctx.now.()
    filters = filters(opts)
    params = [limit: Keyword.get(opts, :limit, 20)] ++ filters

    with {:ok, interval_ms} <- interval_ms(opts),
         {:ok, page} <- page(ctx, params),
         {:ok, page} <- with_deliveries(ctx, page, opts[:deliveries]) do
      if opts[:follow] do
        Enum.each(page, &print(ctx, &1))
        follow(ctx, filters, interval_ms, Feed.mark(Feed.new(since), page), opts[:deliveries])
      else
        {:ok, %{"notifications" => page}, Enum.flat_map(page, &lines/1)}
      end
    end
  end

  # X-33
  @doc "The list filters of `logs` and `listen`: `--workflow`, `--subscriber` and `--status`."
  @spec filters(keyword()) :: keyword()
  def filters(opts) do
    for key <- [:workflow, :subscriber, :status], is_binary(opts[key]), do: {key, opts[key]}
  end

  @doc "The polling interval of `--interval` in milliseconds; 2 seconds by default."
  @spec interval_ms(keyword()) :: {:ok, pos_integer()} | {:error, Failure.t()}
  def interval_ms(opts) do
    case Keyword.get(opts, :interval, 2) do
      seconds when seconds in 1..3600 -> {:ok, seconds * 1000}
      _other -> {:error, Failure.new(:usage, "usage_error", "--interval is 1 to 3600 seconds")}
    end
  end

  @doc "Readable lines of a notification and of its deliveries when present."
  @spec lines(map()) :: [String.t()]
  def lines(%{} = notification) do
    workflow = get_in(notification, ["workflow", "key"])
    recipient = notification["external_id"] || notification["recipient_id"]

    head =
      "#{notification["created_at"]} #{notification["id"]} #{workflow} -> #{recipient} " <>
        "#{notification["state"]}#{counts(notification["delivery_counts"])}"

    [head | Enum.map(Map.get(notification, "deliveries", []), &delivery_line/1)]
  end

  defp follow(ctx, filters, interval_ms, feed, deliveries?) do
    handle = fn notifications -> Enum.each(notifications, &print_new(ctx, &1, deliveries?)) end

    case Feed.follow(ctx, filters, interval_ms, feed, handle) do
      {:ok, summary} ->
        data = %{"polls" => summary.polls, "notifications" => summary.notifications}
        {:ok, data, ["#{summary.notifications} new notification(s) in #{summary.polls} poll(s)"]}

      {:error, _failure} = error ->
        error
    end
  end

  defp print_new(ctx, notification, deliveries?) do
    case with_deliveries(ctx, [notification], deliveries?) do
      {:ok, [notification]} -> print(ctx, notification)
      {:error, failure} -> Output.warn(ctx, failure.message)
    end
  end

  defp print(ctx, notification),
    do: Output.item(ctx, "notification", notification, Enum.join(lines(notification), "\n"))

  defp page(ctx, params) do
    case Client.call(ctx, ctx.config.environment, :get, "/v1/notifications", params: params) do
      {:ok, %{body: %{"data" => page}}} when is_list(page) -> {:ok, page}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  defp with_deliveries(_ctx, page, deliveries?) when deliveries? != true, do: {:ok, page}

  defp with_deliveries(ctx, page, true) do
    Enum.reduce_while(page, {:ok, []}, fn notification, {:ok, acc} ->
      case deliveries(ctx, notification["id"]) do
        {:ok, list} -> {:cont, {:ok, acc ++ [Map.put(notification, "deliveries", list)]}}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  defp deliveries(ctx, id) when is_binary(id) do
    path = "/v1/notifications/" <> Client.segment(id) <> "/deliveries"
    Client.list_all(ctx, ctx.config.environment, path, limit: 100)
  end

  defp deliveries(_ctx, _id), do: {:ok, []}

  defp counts(%{} = counts) do
    @counts
    |> Enum.filter(&(is_integer(counts[&1]) and counts[&1] > 0))
    |> Enum.map_join("", fn key -> " #{key}=#{counts[key]}" end)
  end

  defp counts(_counts), do: ""

  defp delivery_line(%{} = delivery) do
    reason = if delivery["reason"], do: " (#{delivery["reason"]})", else: ""
    "    #{delivery["id"]} #{delivery["channel"]} #{delivery["status"]}#{reason}"
  end

  defp delivery_line(other), do: "    #{inspect(other)}"
end
