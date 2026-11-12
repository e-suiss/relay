defmodule Relay.CLI.Definitions do
  @moduledoc """
  File-based workflow, template and route definitions (X-33, WF-3, WF-6), laid out by `Relay.CLI.DefinitionFile` under `--dir` (default `relay`).

  * `relay pull [key...]` writes the active definitions of the environment (`--kind` narrows them; keys narrow them further): a route as it is, a template or workflow as its draft, or its published version when it has no draft. A definition whose file exists keeps that file and its format; a new one is written as `--format json` (default) or `yaml`.
  * `relay push [file...]` reads the files (by default every file of `--dir` for the chosen kinds), checks them all against the contract schema before anything is sent, and writes routes, then templates, then workflows: each as a draft, skipped when unchanged, and with `--publish` published (`--note`, `--accept-warnings` for template warnings). A workflow managed from the panel is refused unless `--manage-as-code` makes code its single manager (WF-4). A rejected publication fails with the gate's errors and their pointers.
  * `relay promote <key...>` copies published definitions from `test` to `live` and publishes them there (`--kind`, default `workflow`; `--version` for one key); `promote --all` copies every published route, template and workflow. It always changes `live`, so it needs confirmation.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Confirm
  alias Relay.CLI.DefinitionFile
  alias Relay.CLI.Failure
  alias Relay.CLI.Files
  alias Relay.CLI.Remote

  @dir "relay"

  # X-33
  # WF-3
  # WF-6
  # API-69
  @impl Relay.CLI.Command
  def run(ctx, %Args{command: "pull"} = args), do: pull(ctx, args)
  def run(ctx, %Args{command: "push"} = args), do: push(ctx, args)
  def run(ctx, %Args{command: "promote"} = args), do: promote(ctx, args)

  defp pull(ctx, %Args{positional: keys, opts: opts}) do
    environment = ctx.config.environment
    dir = Keyword.get(opts, :dir, @dir)

    with {:ok, kinds} <- kinds(opts),
         {:ok, format} <- format(opts),
         {:ok, pulled} <- each(kinds, &pull_kind(ctx, environment, {dir, format, keys}, &1)) do
      pulled = List.flatten(pulled)
      {:ok, %{"directory" => dir, "definitions" => pulled}, Enum.map(pulled, &pulled_line/1)}
    end
  end

  defp pull_kind(ctx, environment, {_dir, _format, keys} = target, kind) do
    with {:ok, items} <- Remote.list(ctx, environment, kind) do
      items
      |> Enum.filter(&(keys == [] or &1["key"] in keys))
      |> each(&pull_one(ctx, environment, target, kind, &1))
    end
  end

  defp pull_one(ctx, environment, {dir, format, _keys}, kind, item) do
    with {:ok, body, source} <- Remote.pulled(ctx, environment, kind, item) do
      entry =
        %{"kind" => DefinitionFile.name(kind), "key" => item["key"], "source" => source}
        |> put_present("managed_by", item["managed_by"])

      write(entry, body, DefinitionFile.path(dir, kind, item["key"], format))
    end
  end

  defp write(entry, nil, _path), do: {:ok, Map.put(entry, "file", nil)}

  defp write(entry, body, path) do
    case Files.write(path, DefinitionFile.render(path, body)) do
      :ok ->
        {:ok, Map.put(entry, "file", path)}

      {:error, reason} ->
        {:error, Failure.new(:unexpected, "file_write_failed", Files.describe(path, reason))}
    end
  end

  defp pulled_line(%{"kind" => kind, "key" => key, "file" => nil}),
    do: "skipped #{kind} #{key}: no draft or version"

  defp pulled_line(%{"kind" => kind, "key" => key, "file" => file, "source" => source} = entry) do
    manager = if entry["managed_by"], do: ", managed by #{entry["managed_by"]}", else: ""
    "pulled #{kind} #{key} (#{source}#{manager}) -> #{file}"
  end

  defp push(ctx, %Args{positional: files, opts: opts}) do
    environment = ctx.config.environment

    with {:ok, kinds} <- kinds(opts),
         {:ok, paths} <- push_paths(files, Keyword.get(opts, :dir, @dir), kinds),
         {:ok, documents} <- each(paths, &DefinitionFile.read/1),
         :ok <- DefinitionFile.check(documents),
         action = "push writes #{length(documents)} definition(s)",
         :ok <- Confirm.live(ctx, environment, action),
         options = options(opts),
         {:ok, pushed} <- each(ordered(documents), &Remote.push(ctx, environment, &1, options)) do
      {:ok, %{"definitions" => pushed}, Enum.map(pushed, &pushed_line/1)}
    end
  end

  defp options(opts) do
    %{
      publish: opts[:publish] == true,
      note: opts[:note],
      accept_warnings: opts[:accept_warnings] == true,
      manage_as_code: opts[:manage_as_code] == true
    }
  end

  defp push_paths([], dir, kinds) do
    case DefinitionFile.discover(dir, kinds) do
      [] -> usage("no definition files in #{dir}/routes, #{dir}/templates or #{dir}/workflows")
      paths -> {:ok, paths}
    end
  end

  defp push_paths(files, _dir, _kinds) do
    each(files, fn path ->
      with {:ok, kind} <- DefinitionFile.kind_of(path), do: {:ok, {path, kind}}
    end)
  end

  defp ordered(documents) do
    rank = DefinitionFile.kinds() |> Enum.with_index() |> Map.new()
    Enum.sort_by(documents, &{Map.fetch!(rank, &1.kind), &1.key})
  end

  defp pushed_line(%{"kind" => kind, "key" => key, "result" => result} = entry) do
    case entry["publication"] do
      nil -> "#{kind} #{key}: #{draft_word(kind)}#{result}"
      publication -> "#{kind} #{key}: #{draft_word(kind)}#{result}, #{published(publication)}"
    end
  end

  defp draft_word("route"), do: ""
  defp draft_word(_kind), do: "draft "

  defp published(%{"status" => "current", "version" => version}),
    do: "version #{version} already published"

  defp published(%{"status" => "published", "version" => version}),
    do: "published version #{version}"

  defp published(%{"status" => status}), do: "publication #{status}"
  defp published(_publication), do: "publication requested"

  defp promote(ctx, %Args{positional: keys, opts: opts}) do
    with {:ok, kind} <- promote_kind(opts),
         :ok <- promote_args(keys, opts),
         :ok <- Confirm.live(ctx, :live, "promote publishes definitions from test"),
         {:ok, targets} <- targets(ctx, kind, keys, opts),
         {:ok, promoted} <- each(targets, &promote_one(ctx, &1, opts)) do
      {:ok, %{"definitions" => promoted}, Enum.map(promoted, &promoted_line/1)}
    end
  end

  defp promote_kind(opts) do
    case opts[:kind] do
      nil -> {:ok, :workflow}
      name -> kind_name(name)
    end
  end

  defp promote_args([], opts) do
    if opts[:all], do: :ok, else: usage("promote needs keys or --all")
  end

  defp promote_args(keys, opts) do
    cond do
      opts[:all] -> usage("promote takes keys or --all, not both")
      opts[:version] != nil and length(keys) > 1 -> usage("--version takes exactly one key")
      true -> :ok
    end
  end

  defp targets(_ctx, kind, [_ | _] = keys, opts),
    do: {:ok, for(key <- keys, do: {kind, key, opts[:version]})}

  defp targets(ctx, _kind, [], _opts) do
    with {:ok, lists} <- each(DefinitionFile.kinds(), &published_keys(ctx, &1)) do
      {:ok, List.flatten(lists)}
    end
  end

  defp published_keys(ctx, kind) do
    with {:ok, items} <- Remote.list(ctx, :test, kind) do
      {:ok, for(item <- items, published?(kind, item), do: {kind, item["key"], nil})}
    end
  end

  defp published?(:route, _route), do: true
  defp published?(:template, template), do: is_integer(template["live_version"])
  defp published?(:workflow, workflow), do: is_integer(workflow["published_version"])

  defp promote_one(ctx, {kind, key, version}, opts) do
    with {:ok, body, number} <- Remote.published(ctx, :test, kind, key, version) do
      note = opts[:note] || promoted_note(number)
      file = %{kind: kind, key: key, path: nil, body: body}
      options = %{options(opts) | publish: true, note: note}

      with {:ok, result} <- Remote.push(ctx, :live, file, options) do
        {:ok, Map.put(result, "source", %{"environment" => "test", "version" => number})}
      end
    end
  end

  defp promoted_note(nil), do: "promoted from test"
  defp promoted_note(number), do: "promoted from test version #{number}"

  defp promoted_line(%{"kind" => kind, "key" => key, "source" => source} = entry) do
    from = if source["version"], do: "test version #{source["version"]}", else: "test"

    case entry["publication"] do
      nil -> "promoted #{kind} #{key} from #{from} to live: #{entry["result"]}"
      publication -> "promoted #{kind} #{key} from #{from} to live: #{published(publication)}"
    end
  end

  defp kinds(opts) do
    case Keyword.get_values(opts, :kind) do
      [] -> {:ok, DefinitionFile.kinds()}
      names -> each(names, &kind_name/1)
    end
  end

  defp kind_name(name) do
    case DefinitionFile.kind(name) do
      {:ok, kind} -> {:ok, kind}
      :error -> usage("--kind is route, template or workflow")
    end
  end

  defp format(opts) do
    case DefinitionFile.format(Keyword.get(opts, :format, "json")) do
      {:ok, format} -> {:ok, format}
      :error -> usage("--format is json or yaml")
    end
  end

  defp each(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _failure} = error -> error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
