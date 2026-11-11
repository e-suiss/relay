defmodule Relay.CLI.DefinitionFile do
  @moduledoc """
  The definition files of `relay pull`, `relay push` and `relay promote`. A directory holds one subdirectory per kind, `routes/`, `templates/` and `workflows/`, with one file per definition named by its key: `<key>.json` or `<key>.yaml` (`.yml` is read too).

  A file holds the body that creates the definition through the API, so the files and the API carry the same data model (WF-3, WF-59): a route is `{key, name, tree}` (`createRoute`), a template `{key, name, category, definition}` (`createTemplate`) and a workflow `{key, definition}` (`createWorkflow`). JSON and YAML are two spellings of that model. Files are written with their keys in sorted order, so the same definition always gives the same bytes and a git diff shows only what changed.

  Before anything is sent, every file is checked against the contract schema of its body and its key against its file name; every error is reported with its file and RFC 6901 pointer.
  """

  alias Relay.Api.Schema
  alias Relay.CLI.Failure
  alias Relay.CLI.Files
  alias Relay.CLI.Yaml

  @kinds [:route, :template, :workflow]
  @dirs %{route: "routes", template: "templates", workflow: "workflows"}
  @names %{"route" => :route, "template" => :template, "workflow" => :workflow}
  @schemas %{route: "RouteCreate", template: "TemplateCreate", workflow: "WorkflowCreate"}
  @extensions %{".json" => :json, ".yaml" => :yaml, ".yml" => :yaml}
  @safe_key ~r/\A[a-z0-9][a-z0-9_-]{0,99}\z/

  @type kind :: :route | :template | :workflow
  @type format :: :json | :yaml
  @type t :: %{kind: kind(), key: String.t(), path: Path.t() | nil, body: map()}

  @doc "The kinds in the order they are written: routes and templates before the workflows that name them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kind named on the command line (`route`, `template` or `workflow`, singular or plural)."
  @spec kind(String.t()) :: {:ok, kind()} | :error
  def kind(name) when is_binary(name), do: Map.fetch(@names, String.trim_trailing(name, "s"))

  @doc "The name of a kind in output."
  @spec name(kind()) :: String.t()
  def name(kind), do: Atom.to_string(kind)

  @doc "The file format named on the command line."
  @spec format(String.t()) :: {:ok, format()} | :error
  def format("json"), do: {:ok, :json}
  def format("yaml"), do: {:ok, :yaml}
  def format(_other), do: :error

  @doc "Whether a key read from the API is safe to use as a file name."
  @spec safe_key?(term()) :: boolean()
  def safe_key?(key), do: is_binary(key) and Regex.match?(@safe_key, key)

  @doc "The file of a definition: the existing file of its key in either format, otherwise a new file in `format`."
  @spec path(Path.t(), kind(), String.t(), format()) :: Path.t()
  def path(dir, kind, key, format) do
    base = Path.join([dir, Map.fetch!(@dirs, kind), key])

    Enum.find(Enum.map(Map.keys(@extensions), &(base <> &1)), &Files.regular?/1) ||
      base <> "." <> Atom.to_string(format)
  end

  # X-33
  # WF-59
  @doc "The bytes of a definition file: the body with sorted keys, as JSON or YAML according to the file's extension."
  @spec render(Path.t(), map()) :: iodata()
  def render(path, body) do
    case Map.fetch!(@extensions, Path.extname(path)) do
      :json -> [body |> ordered() |> Jason.encode!(pretty: true), ?\n]
      :yaml -> Yaml.encode(body)
    end
  end

  defp ordered(%{} = map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  @doc "The definition files of a directory for the given kinds, sorted by kind and name."
  @spec discover(Path.t(), [kind()]) :: [{Path.t(), kind()}]
  def discover(dir, kinds) do
    for kind <- @kinds,
        kind in kinds,
        path <- Files.list(Path.join(dir, Map.fetch!(@dirs, kind))),
        Map.has_key?(@extensions, Path.extname(path)),
        do: {path, kind}
  end

  @doc "The kind of a file named on the command line, from the directory it is in."
  @spec kind_of(Path.t()) :: {:ok, kind()} | {:error, Failure.t()}
  def kind_of(path) do
    dir = path |> Path.dirname() |> Path.basename()

    case Enum.find(@kinds, &(Map.fetch!(@dirs, &1) == dir)) do
      nil -> usage("#{path} must be in a routes, templates or workflows directory")
      kind -> {:ok, kind}
    end
  end

  # X-33
  # WF-59
  @doc "Reads and decodes one definition file."
  @spec read({Path.t(), kind()}) :: {:ok, t()} | {:error, Failure.t()}
  def read({path, kind}) do
    with {:ok, format} <- extension(path),
         {:ok, content} <- content(path),
         {:ok, body} <- decode(path, format, content) do
      {:ok, %{kind: kind, key: Path.basename(path, Path.extname(path)), path: path, body: body}}
    end
  end

  defp extension(path) do
    case Map.fetch(@extensions, Path.extname(path)) do
      {:ok, format} -> {:ok, format}
      :error -> usage("#{path} is not a .json, .yaml or .yml file")
    end
  end

  defp content(path) do
    case Files.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> usage(Files.describe(path, reason))
    end
  end

  defp decode(path, :json, content) do
    case Jason.decode(content) do
      {:ok, %{} = body} -> {:ok, body}
      {:ok, _other} -> invalid(path, "the file must hold a JSON object")
      {:error, error} -> invalid(path, "the file is not JSON: " <> Exception.message(error))
    end
  end

  defp decode(path, :yaml, content) do
    case Yaml.decode(content) do
      {:ok, %{} = body} -> {:ok, body}
      {:ok, _other} -> invalid(path, "the file must hold a YAML mapping")
      {:error, message} -> invalid(path, message)
    end
  end

  # X-33
  # WF-59
  # API-37
  @doc "Checks every file before anything is sent: its body against the contract schema of its kind, its key against its file name, and that no key appears twice in a kind. Every error is reported at once."
  @spec check([t()]) :: :ok | {:error, Failure.t()}
  def check(files) do
    roots = for kind <- Enum.uniq(Enum.map(files, & &1.kind)), into: %{}, do: {kind, root(kind)}

    errors =
      Enum.flat_map(files, &file_errors(&1, Map.fetch!(roots, &1.kind))) ++
        (files |> Enum.group_by(&{&1.kind, &1.key}) |> Enum.flat_map(&duplicates/1))

    case errors do
      [] ->
        :ok

      _errors ->
        message = "#{length(errors)} error(s) in the definition files; nothing was sent"
        failure = Failure.new(:invalid, "invalid_definition_file", message)
        {:error, %{failure | response: %{"errors" => errors}}}
    end
  end

  defp file_errors(file, root) do
    schema =
      case Schema.validate(root, file.body) do
        :ok -> []
        {:error, %Relay.Error{details: %{errors: errors}}} -> Enum.map(errors, &error(file, &1))
      end

    schema ++ key_errors(file)
  end

  defp key_errors(%{body: %{"key" => key}, key: key}), do: []

  defp key_errors(%{body: %{"key" => key}} = file) when is_binary(key) do
    detail = "the file is named #{file.key}"
    [error(file, %{pointer: "/key", code: "conflict", detail: detail})]
  end

  defp key_errors(_file), do: []

  defp duplicates({_kind_key, [_one]}), do: []

  defp duplicates({_kind_key, [first | _rest] = files}) do
    paths = Enum.map_join(files, ", ", & &1.path)
    [error(first, %{pointer: "/key", code: "conflict", detail: "the key is in #{paths}"})]
  end

  defp error(file, %{pointer: pointer, code: code, detail: detail}),
    do: %{"file" => file.path, "pointer" => pointer, "code" => code, "detail" => detail}

  defp root(kind),
    do: Schema.build(%{"$ref" => "#/$defs/schemas." <> Map.fetch!(@schemas, kind)})

  defp invalid(path, detail) do
    failure = Failure.new(:invalid, "invalid_definition_file", "#{path}: #{detail}")
    {:error, failure}
  end

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
