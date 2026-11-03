defmodule Relay.CLI.Preview do
  @moduledoc """
  `relay preview <workflow>`: previews with local data.

    * Without options beyond the event options it runs an event as a dry run, `POST /v1/events` with `send_mode: dry_run` (operation `createEvent`). Relay validates the data against the published workflow version and runs its decisions without opening deliveries. A per-request send mode exists only in the `test` environment, so a `live` client is refused before anything is sent.
    * With `--template <key>` it renders that template per channel with the workflow's event schema, `POST /v1/templates/{key}/preview` (operation `previewTemplate`), and prints each channel's render, SMS encoding and segments and warnings. `--channel` (repeatable), `--locale`, `--version` (`draft`, `live` or a number) and `--sample` (`schema_examples`, `masked_recent`, `boundary`) narrow it; `--data` or `--data-file` gives the event data.
    * With `--steps` it previews the workflow's steps, `POST /v1/workflows/{key}/preview` (operation `previewWorkflow`): for each step whether it would send, the `rule_id` that stops it and the render.

  Template and step previews send nothing and open no record, so they run with a `live` client too.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Failure
  alias Relay.CLI.Trigger

  @samples ["schema_examples", "masked_recent", "boundary"]

  # X-33
  # API-60
  # API-62
  @impl Relay.CLI.Command
  def run(ctx, %Args{opts: opts} = args) do
    cond do
      opts[:template] -> template(ctx, args)
      opts[:steps] -> steps(ctx, args)
      true -> dry_run(ctx, args)
    end
  end

  defp dry_run(ctx, args) do
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

  # API-60
  # TP-38
  defp template(ctx, %Args{positional: [workflow], opts: opts}) do
    key = opts[:template]
    path = "/v1/templates/" <> Client.segment(key) <> "/preview"

    with :ok <- Trigger.workflow_key(workflow),
         :ok <- template_key(key),
         {:ok, body} <- request(%{"workflow" => workflow}, opts),
         {:ok, response} <- Client.call(ctx, ctx.config.environment, :post, path, json: body) do
      {:ok, response.body, render_lines(response.body)}
    end
  end

  # API-60
  defp steps(ctx, %Args{positional: [workflow], opts: opts}) do
    path = "/v1/workflows/" <> Client.segment(workflow) <> "/preview"

    with :ok <- Trigger.workflow_key(workflow),
         {:ok, body} <- request(%{}, opts),
         body = put_present(body, "to", List.first(Keyword.get_values(opts, :to))),
         {:ok, response} <- Client.call(ctx, ctx.config.environment, :post, path, json: body) do
      {:ok, response.body, step_lines(response.body)}
    end
  end

  defp template_key(key) do
    case Trigger.workflow_key(key) do
      :ok -> :ok
      {:error, _failure} -> usage("#{key} is not a template key")
    end
  end

  defp request(body, opts) do
    with {:ok, data} <- Trigger.data(opts),
         {:ok, version} <- version(opts[:version]),
         {:ok, sample} <- sample(opts[:sample]) do
      {:ok,
       body
       |> put_present("data", data)
       |> put_present("version", version)
       |> put_present("sample", sample)
       |> put_present("locale", opts[:locale])
       |> put_present("channels", channels(opts))}
    end
  end

  defp channels(opts) do
    case Keyword.get_values(opts, :channel) do
      [] -> nil
      channels -> Enum.uniq(channels)
    end
  end

  defp version(nil), do: {:ok, nil}
  defp version(label) when label in ["draft", "live"], do: {:ok, label}

  defp version(text) do
    case Integer.parse(text) do
      {number, ""} when number >= 1 -> {:ok, number}
      _other -> usage("--version takes draft, live or a version number")
    end
  end

  defp sample(nil), do: {:ok, nil}
  defp sample(sample) when sample in @samples, do: {:ok, sample}
  defp sample(_sample), do: usage("--sample takes schema_examples, masked_recent or boundary")

  @doc "Readable lines of a template preview."
  @spec render_lines(term()) :: [String.t()]
  def render_lines(%{"renders" => renders} = preview) when is_list(renders) do
    head = "preview of #{preview["template_key"]} (#{preview["version"]}, #{preview["sample"]})"
    [head | Enum.flat_map(renders, &render_line/1)]
  end

  def render_lines(_body), do: ["preview"]

  @doc "Readable lines of a workflow step preview."
  @spec step_lines(term()) :: [String.t()]
  def step_lines(%{"steps" => steps} = preview) when is_list(steps) do
    head = "preview of #{preview["workflow_key"]} (#{preview["version"]}, #{preview["sample"]})"
    [head | Enum.flat_map(steps, &step_line/1)]
  end

  def step_lines(_body), do: ["preview"]

  defp step_line(%{"step" => step} = row) do
    why = row["rule_id"] || row["reason"]
    verdict = if row["would_send"], do: "sends", else: "skipped #{why}"
    ["  #{step} #{row["channel"]} #{row["template"]}: #{verdict}"] ++ render_line(row["render"])
  end

  defp step_line(other), do: ["  #{inspect(other)}"]

  defp render_line(%{"channel" => channel} = render) do
    state = if render["failure_reason"], do: "failed #{render["failure_reason"]}", else: "ok"
    sms = sms_line(render["sms"])
    warnings = Enum.map(render["warnings"] || [], &"    warning: #{&1["code"]} #{&1["message"]}")
    ["  #{channel} #{render["locale"]}: #{state}" | sms] ++ warnings
  end

  defp render_line(_render), do: []

  defp sms_line(%{"encoding" => encoding} = sms) do
    [
      "    SMS #{encoding}, #{sms["segments"]} segment(s), #{sms["characters"]} character(s); " <>
        "unverified provider: #{sms["encoding_unverified_provider"]}"
    ]
  end

  defp sms_line(_sms), do: []

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
