defmodule Relay.CLI.Trigger do
  @moduledoc """
  `relay trigger <workflow>`: sends an event to a workflow with `POST /v1/events` (operation `createEvent`). Recipients are external ids (`--to`) or recipient objects (`--recipient`, an explicit upsert); `--data` or `--data-file` gives the event data object. With a `live` client the event reaches real people, so it needs confirmation.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Confirm
  alias Relay.CLI.Failure
  alias Relay.CLI.Files

  @workflow_key ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @recipient_hint ~s(--recipient takes a JSON object such as {"id": "user-1"})

  # X-33
  # L-30
  @impl Relay.CLI.Command
  def run(ctx, %Args{} = args) do
    environment = ctx.config.environment

    with {:ok, event} <- event(args),
         :ok <- Confirm.live(ctx, environment, "trigger sends an event to #{event["workflow"]}"),
         {:ok, response} <- Client.call(ctx, environment, :post, "/v1/events", json: event) do
      {:ok, response.body, accepted_lines("accepted", response.body)}
    end
  end

  # X-33
  @doc "Builds the event request of `trigger` and `preview` from the workflow argument and the event options."
  @spec event(Args.t()) :: {:ok, map()} | {:error, Failure.t()}
  def event(%Args{positional: [workflow], opts: opts}) do
    with :ok <- workflow_key(workflow),
         {:ok, recipients} <- recipients(opts),
         {:ok, data} <- data(opts) do
      event =
        %{"workflow" => workflow, "to" => recipients}
        |> put_present("data", data)
        |> put_present("dedup_key", opts[:dedup_key])

      {:ok, event}
    end
  end

  @doc "Returns `:ok` for a valid workflow key, otherwise a usage failure."
  @spec workflow_key(String.t()) :: :ok | {:error, Failure.t()}
  def workflow_key(key) when is_binary(key) do
    if byte_size(key) <= 100 and Regex.match?(@workflow_key, key),
      do: :ok,
      else: usage("#{key} is not a workflow key (lowercase letters, digits and dashes)")
  end

  @doc "Readable lines of an accepted event."
  @spec accepted_lines(String.t(), term()) :: [String.t()]
  def accepted_lines(verb, %{"id" => id} = event) do
    notifications = Map.get(event, "notifications", [])
    warnings = Enum.map(Map.get(event, "warnings", []), &warning_line/1)
    head = "#{verb} event #{id} with #{length(notifications)} notification(s)"
    [head | Enum.map(notifications, &notification_line/1) ++ warnings]
  end

  def accepted_lines(verb, _body), do: [verb]

  defp notification_line(%{} = notification) do
    recipient = notification["external_id"] || notification["recipient_id"]

    duplicate =
      case notification["duplicate_of"] do
        nil -> ""
        event -> " (duplicate of #{event})"
      end

    "  #{notification["notification_id"]} -> #{recipient}#{duplicate}"
  end

  defp notification_line(other), do: "  #{inspect(other)}"

  defp warning_line(%{"code" => code} = warning), do: "  warning: #{code} #{warning["detail"]}"
  defp warning_line(other), do: "  warning: #{inspect(other)}"

  defp recipients(opts) do
    ids = Keyword.get_values(opts, :to)

    objects =
      Enum.reduce_while(Keyword.get_values(opts, :recipient), {:ok, []}, fn text, {:ok, acc} ->
        case Jason.decode(text) do
          {:ok, %{} = object} -> {:cont, {:ok, acc ++ [object]}}
          _other -> {:halt, usage(@recipient_hint)}
        end
      end)

    case objects do
      {:ok, []} when ids == [] ->
        usage("name at least one recipient with --to or --recipient")

      {:ok, objects} ->
        {:ok, ids ++ objects}

      {:error, _failure} = error ->
        error
    end
  end

  defp data(opts) do
    case {opts[:data], opts[:data_file]} do
      {nil, nil} -> {:ok, nil}
      {text, nil} -> json_object(text, "--data")
      {nil, path} -> read_object(path)
      {_text, _path} -> usage("give --data or --data-file, not both")
    end
  end

  defp read_object(path) do
    case Files.read(path) do
      {:ok, content} -> json_object(content, "--data-file")
      {:error, reason} -> usage(Files.describe(path, reason))
    end
  end

  defp json_object(text, option) do
    case Jason.decode(text) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> usage("#{option} must be a JSON object")
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
