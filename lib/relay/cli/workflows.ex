defmodule Relay.CLI.Workflows do
  @moduledoc """
  File-based workflow definitions. A workflow file is JSON, `<dir>/<key>.json`, holding `{"key": ..., "definition": ...}`: the body of `createWorkflow`, so the file format and the API carry the same definition.

  * `relay pull [workflow...]` lists the workflows (`listWorkflows`), reads each (`getWorkflow`) and writes its draft, or its published version (`getWorkflowVersion`) when it has no draft.
  * `relay push [file...]` reads the files (by default every `*.json` of `--dir`) and writes each as a draft: `createWorkflow` for a new key, otherwise `replaceWorkflowDraft` with the workflow's ETag in `If-Match`, skipped when the draft is unchanged; `--publish` then publishes it (`publishWorkflow`).
  * `relay promote <workflow>` reads the published version of a workflow with the `test` client (`getWorkflow`, `getWorkflowVersion`; `--version` picks another version), writes it as the draft of the same workflow with the `live` client and publishes it there. It always changes `live`, so it needs confirmation.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Client
  alias Relay.CLI.Confirm
  alias Relay.CLI.Failure
  alias Relay.CLI.Files
  alias Relay.CLI.HTTP
  alias Relay.CLI.Trigger

  @dir "workflows"

  # X-33
  # API-69
  @impl Relay.CLI.Command
  def run(ctx, %Args{command: "pull"} = args), do: pull(ctx, args)
  def run(ctx, %Args{command: "push"} = args), do: push(ctx, args)
  def run(ctx, %Args{command: "promote"} = args), do: promote(ctx, args)

  defp pull(ctx, %Args{positional: keys, opts: opts}) do
    environment = ctx.config.environment
    dir = Keyword.get(opts, :dir, @dir)

    with {:ok, keys} <- keys(ctx, environment, keys),
         {:ok, pulled} <- each(keys, &pull_one(ctx, environment, dir, &1)) do
      {:ok, %{"directory" => dir, "workflows" => pulled}, Enum.map(pulled, &pulled_line/1)}
    end
  end

  defp keys(ctx, environment, []) do
    case Client.list_all(ctx, environment, "/v1/workflows", limit: 100) do
      {:ok, workflows} -> {:ok, for(%{"key" => key} <- workflows, valid_key?(key), do: key)}
      {:error, _failure} = error -> error
    end
  end

  defp keys(_ctx, _environment, keys), do: each(keys, &key/1)

  defp key(key) do
    case Trigger.workflow_key(key) do
      :ok -> {:ok, key}
      {:error, _failure} = error -> error
    end
  end

  defp pull_one(ctx, environment, dir, key) do
    with {:ok, workflow, _etag} <- get_workflow(ctx, environment, key),
         {:ok, definition, source} <- pulled_definition(ctx, environment, key, workflow) do
      write(dir, key, definition, source)
    end
  end

  defp pulled_definition(_ctx, _environment, _key, %{"draft" => %{} = draft}),
    do: {:ok, draft, "draft"}

  defp pulled_definition(ctx, environment, key, %{"published_version" => version})
       when is_integer(version) do
    case version_definition(ctx, environment, key, version) do
      {:ok, definition} -> {:ok, definition, "version #{version}"}
      {:error, _failure} = error -> error
    end
  end

  defp pulled_definition(_ctx, _environment, _key, _workflow), do: {:ok, nil, "none"}

  defp write(_dir, key, nil, source),
    do: {:ok, %{"key" => key, "file" => nil, "source" => source}}

  defp write(dir, key, definition, source) do
    path = Path.join(dir, key <> ".json")
    document = Jason.encode!(%{"key" => key, "definition" => definition}, pretty: true)

    case Files.write(path, [document, "\n"]) do
      :ok ->
        {:ok, %{"key" => key, "file" => path, "source" => source}}

      {:error, reason} ->
        {:error, Failure.new(:unexpected, "file_write_failed", Files.describe(path, reason))}
    end
  end

  defp pulled_line(%{"key" => key, "file" => nil}), do: "skipped #{key}: no draft or version"

  defp pulled_line(%{"key" => key, "file" => file, "source" => source}),
    do: "pulled #{key} (#{source}) -> #{file}"

  defp push(ctx, %Args{positional: files, opts: opts}) do
    environment = ctx.config.environment

    with {:ok, paths} <- push_paths(files, Keyword.get(opts, :dir, @dir)),
         {:ok, documents} <- each(paths, &read_definition/1),
         :ok <- Confirm.live(ctx, environment, "push writes #{length(documents)} workflow(s)"),
         {:ok, pushed} <- each(documents, &push_one(ctx, environment, &1, opts)) do
      {:ok, %{"workflows" => pushed}, Enum.map(pushed, &pushed_line/1)}
    end
  end

  defp push_paths([], dir) do
    case Files.json_files(dir) do
      [] -> usage("no workflow files (*.json) in #{dir}")
      paths -> {:ok, paths}
    end
  end

  defp push_paths(files, _dir), do: {:ok, files}

  defp read_definition(path) do
    with {:ok, content} <- read_file(path),
         {:ok, key, definition} <- parse_definition(content) do
      {:ok, %{path: path, key: key, definition: definition}}
    else
      :invalid -> invalid_file(path)
      {:error, %Failure{}} = error -> error
    end
  end

  defp read_file(path) do
    case Files.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> usage(Files.describe(path, reason))
    end
  end

  defp parse_definition(content) do
    case Jason.decode(content) do
      {:ok, %{"key" => key, "definition" => %{} = definition} = document}
      when map_size(document) == 2 ->
        if valid_key?(key), do: {:ok, key, definition}, else: :invalid

      _other ->
        :invalid
    end
  end

  defp invalid_file(path) do
    message = "#{path} must hold a JSON object with exactly a workflow key and a definition"
    {:error, Failure.new(:invalid, "invalid_workflow_file", message)}
  end

  defp push_one(ctx, environment, document, opts) do
    with {:ok, draft, etag} <- write_draft(ctx, environment, document.key, document.definition),
         {:ok, publication} <- maybe_publish(ctx, environment, document.key, etag, opts) do
      {:ok,
       %{
         "key" => document.key,
         "file" => document.path,
         "draft" => draft,
         "publication" => publication
       }}
    end
  end

  defp maybe_publish(ctx, environment, key, etag, opts) do
    if opts[:publish], do: publish(ctx, environment, key, etag, opts[:note]), else: {:ok, nil}
  end

  defp pushed_line(%{"key" => key, "draft" => draft, "publication" => nil}),
    do: "#{key}: draft #{draft}"

  defp pushed_line(%{"key" => key, "draft" => draft, "publication" => publication}),
    do: "#{key}: draft #{draft}, publication #{publication_status(publication)}"

  defp promote(ctx, %Args{positional: [key], opts: opts}) do
    with :ok <- Trigger.workflow_key(key),
         :ok <- Confirm.live(ctx, :live, "promote publishes #{key} from test"),
         {:ok, version} <- source_version(ctx, key, opts[:version]),
         {:ok, definition} <- version_definition(ctx, :test, key, version),
         {:ok, draft, etag} <- write_draft(ctx, :live, key, definition),
         note = opts[:note] || "promoted from test version #{version}",
         {:ok, publication} <- publish(ctx, :live, key, etag, note) do
      data = %{
        "key" => key,
        "source" => %{"environment" => "test", "version" => version},
        "draft" => draft,
        "publication" => publication
      }

      status = publication_status(publication)
      {:ok, data, ["promoted #{key} test version #{version} to live: publication #{status}"]}
    end
  end

  defp source_version(_ctx, _key, version) when is_integer(version) and version >= 1,
    do: {:ok, version}

  defp source_version(_ctx, _key, version) when is_integer(version),
    do: usage("--version is a published version number from 1")

  defp source_version(ctx, key, nil) do
    case get_workflow(ctx, :test, key) do
      {:ok, %{"published_version" => version}, _etag} when is_integer(version) ->
        {:ok, version}

      {:ok, _workflow, _etag} ->
        message = "#{key} has no published version in test"
        {:error, Failure.new(:invalid, "workflow_not_published", message)}

      {:error, _failure} = error ->
        error
    end
  end

  defp get_workflow(ctx, environment, key) do
    case Client.call(ctx, environment, :get, workflow_path(key)) do
      {:ok, %{body: %{"key" => _key} = workflow} = response} ->
        {:ok, workflow, HTTP.header(response, "etag")}

      {:ok, _response} ->
        {:error, Client.unexpected_body()}

      {:error, _failure} = error ->
        error
    end
  end

  defp version_definition(ctx, environment, key, version) do
    path = workflow_path(key) <> "/versions/" <> Client.segment(version)

    case Client.call(ctx, environment, :get, path) do
      {:ok, %{body: %{"definition" => %{} = definition}}} -> {:ok, definition}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  defp write_draft(ctx, environment, key, definition) do
    case get_workflow(ctx, environment, key) do
      {:ok, %{"draft" => ^definition}, etag} ->
        {:ok, "unchanged", etag}

      {:ok, _workflow, etag} ->
        replace_draft(ctx, environment, key, definition, etag)

      {:error, %Failure{status: 404}} ->
        create(ctx, environment, key, definition)

      {:error, _failure} = error ->
        error
    end
  end

  defp create(ctx, environment, key, definition) do
    body = %{"key" => key, "definition" => definition}

    case Client.call(ctx, environment, :post, "/v1/workflows", json: body) do
      {:ok, response} -> {:ok, "created", HTTP.header(response, "etag")}
      {:error, _failure} = error -> error
    end
  end

  defp replace_draft(ctx, environment, key, definition, etag) do
    opts = [json: %{"definition" => definition}, headers: if_match(etag)]

    case Client.call(ctx, environment, :put, workflow_path(key), opts) do
      {:ok, response} -> {:ok, "updated", HTTP.header(response, "etag")}
      {:error, _failure} = error -> error
    end
  end

  defp publish(ctx, environment, key, etag, note) do
    body = if note, do: %{"note" => note}, else: %{}
    opts = [json: body, headers: if_match(etag)]

    case Client.call(ctx, environment, :post, workflow_path(key) <> "/publish", opts) do
      {:ok, %{body: %{"publication" => %{} = publication}}} -> {:ok, publication}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  defp publication_status(%{"status" => status}), do: status
  defp publication_status(_publication), do: "requested"

  defp if_match(nil), do: []
  defp if_match(etag), do: [{"if-match", etag}]

  defp workflow_path(key), do: "/v1/workflows/" <> Client.segment(key)

  defp valid_key?(key), do: is_binary(key) and Trigger.workflow_key(key) == :ok

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

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
