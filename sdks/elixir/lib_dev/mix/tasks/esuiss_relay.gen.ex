defmodule Mix.Tasks.EsuissRelay.Gen do
  @shortdoc "Generates the API layer of the SDK from the Relay contracts"
  @moduledoc """
  Generates `lib/esuiss_relay/generated/*.ex` from `contracts/openapi/server.yaml` and
  `contracts/errors.yaml`. Options: `--contracts PATH` (default `../../contracts`) and
  `--out PATH` (default `lib/esuiss_relay/generated`).

  Every operation whose security accepts an Access token becomes one function of
  `EsuissRelay.Api`; operator-only and unauthenticated operations are left out.
  """

  use Mix.Task

  @methods ["get", "post", "put", "patch", "delete"]
  @request_options ~w(idempotency_key if_match beta headers content_type max_retries timeout body)
  @reserved ~w(client opts body do end fn when and or not in true false nil catch rescue after else)
  @identifier ~r/\A[a-z][a-z0-9_]*\z/

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [contracts: :string, out: :string])
    contracts = Keyword.get(opts, :contracts, Path.expand("../../contracts", File.cwd!()))
    out = Keyword.get(opts, :out, "lib/esuiss_relay/generated")
    {:ok, _started} = Application.ensure_all_started(:yaml_elixir)

    server = read(contracts, "openapi/server.yaml")
    parameters = read(contracts, "openapi/components/parameters.yaml")
    schemas = read(contracts, "openapi/components/schemas.yaml")
    errors = read(contracts, "errors.yaml")

    operations = operations(server, parameters, schemas)
    version = server["info"]["version"]

    File.mkdir_p!(out)
    write(out, "version.ex", version_source(version))
    write(out, "error_catalog.ex", catalog_source(errors))
    write(out, "operations.ex", operations_source(operations))
    write(out, "api.ex", api_source(operations, version))
    Mix.shell().info("generated #{length(operations)} operations for API #{version}")
  end

  defp read(contracts, path), do: contracts |> Path.join(path) |> YamlElixir.read_from_file!()

  defp write(out, name, source) do
    formatted = source |> Code.format_string!() |> IO.iodata_to_binary()
    File.write!(Path.join(out, name), formatted <> "\n")
  end

  defp operations(server, parameters, schemas) do
    server["paths"]
    |> Enum.flat_map(fn {path, item} ->
      for method <- @methods, is_map(item[method]), do: {path, method, item[method]}
    end)
    |> Enum.filter(fn {_path, _method, operation} -> access?(operation, server) end)
    |> Enum.sort_by(fn {path, method, _operation} -> {path, Enum.find_index(@methods, &(&1 == method))} end)
    |> Enum.map(fn {path, method, operation} -> operation(path, method, operation, parameters, schemas) end)
  end

  defp access?(operation, server) do
    operation
    |> Map.get("security", server["security"] || [])
    |> Enum.any?(&Map.has_key?(&1, "access_bearer"))
  end

  defp operation(path, method, operation, parameters, schemas) do
    params = Enum.map(operation["parameters"] || [], &parameter(&1, parameters))
    refs = Enum.map(operation["parameters"] || [], &ref_name/1)
    body = operation["requestBody"]
    query = for p <- params, p["in"] == "query", do: query(p, schemas)

    %{
      name: name(operation["operationId"]),
      summary: operation["summary"] || operation["operationId"],
      method: method,
      path: path,
      path_params: path_params(path),
      query: query,
      idempotency: requirement(refs, "IdempotencyKey", "IdempotencyKeyCloudEvents"),
      if_match: requirement(refs, "IfMatch", "IfMatchOptional"),
      body: body_requirement(body),
      content_type: content_type(body),
      paginated: method == "get" and "StartingAfter" in refs,
      response: response(operation["responses"] || %{})
    }
    |> check()
  end

  defp parameter(%{"$ref" => ref}, parameters), do: Map.fetch!(parameters, fragment(ref))
  defp parameter(inline, _parameters), do: inline

  defp ref_name(%{"$ref" => ref}), do: fragment(ref)
  defp ref_name(_inline), do: nil

  defp fragment(ref), do: ref |> String.split("#/") |> List.last()

  defp query(param, schemas) do
    schema = param["schema"] || %{}

    kind =
      case schema do
        %{"type" => "array"} -> "string_array"
        %{"type" => type} when type in ["integer", "boolean"] -> type
        %{"$ref" => ref} -> ref_kind(Map.get(schemas, fragment(ref), %{}))
        _other -> "string"
      end

    {param["name"], kind, param["required"] == true}
  end

  defp ref_kind(%{"type" => type}) when type in ["integer", "boolean"], do: type
  defp ref_kind(_schema), do: "string"

  defp path_params(path),
    do: ~r/\{([a-z_][a-z0-9_]*)\}/ |> Regex.scan(path) |> Enum.map(fn [_all, name] -> name end)

  defp requirement(refs, required, optional) do
    cond do
      required in refs -> "required"
      optional in refs -> "optional"
      true -> "none"
    end
  end

  defp body_requirement(nil), do: "none"
  defp body_requirement(%{"required" => true}), do: "required"
  defp body_requirement(_body), do: "optional"

  defp content_type(nil), do: nil

  defp content_type(%{"content" => content}) do
    types = Map.keys(content)
    if "application/json" in types, do: "application/json", else: Enum.min(types)
  end

  defp response(responses) do
    types =
      responses
      |> Enum.filter(fn {code, _response} -> String.starts_with?(to_string(code), "2") end)
      |> Enum.flat_map(fn {_code, response} -> Map.keys(response["content"] || %{}) end)

    cond do
      "application/json" in types -> "json"
      "text/plain" in types -> "text"
      true -> "none"
    end
  end

  defp name(operation_id) do
    name = Macro.underscore(operation_id)
    Regex.match?(@identifier, name) || Mix.raise("unusable operation id #{operation_id}")
    name
  end

  defp check(operation) do
    for {name, _kind, _required} <- operation.query do
      Regex.match?(@identifier, name) || Mix.raise("unusable query parameter #{name}")
      name in @request_options && Mix.raise("query parameter #{name} clashes with an option")
    end

    for name <- operation.path_params,
        not Regex.match?(@identifier, name) or name in @reserved,
        do: Mix.raise("unusable path parameter #{name} in #{operation.path}")

    operation
  end

  defp version_source(version) do
    """
    defmodule EsuissRelay.Generated.Version do
      @moduledoc false

      @doc false
      @spec api_version() :: String.t()
      def api_version, do: #{inspect(version)}
    end
    """
  end

  defp catalog_source(errors) do
    codes =
      errors["codes"]
      |> Enum.sort_by(& &1["code"])
      |> Enum.map_join(",\n", fn entry ->
        "#{inspect(entry["code"])} => %{family: #{inspect(entry["family"])}, status: #{entry["status"]}, retryable: #{entry["retryable"] == true}}"
      end)

    defaults =
      Enum.map_join(errors["retryable_defaults"], ",\n", fn entry ->
        "{#{entry["status"]}, #{inspect(entry["code"])}, #{entry["retryable"] == true}}"
      end)

    """
    defmodule EsuissRelay.Generated.ErrorCatalog do
      @moduledoc false

      @codes %{
        #{codes}
      }

      @defaults [
        #{defaults}
      ]

      @doc false
      @spec lookup(String.t()) :: %{family: String.t(), status: pos_integer(), retryable: boolean()} | nil
      def lookup(code), do: Map.get(@codes, code)

      @doc false
      @spec codes() :: map()
      def codes, do: @codes

      @doc false
      @spec default_retryable(non_neg_integer(), String.t() | nil) :: boolean()
      def default_retryable(status, code) do
        exact = Enum.find(@defaults, &match?({^status, ^code, _retryable}, &1))
        generic = Enum.find(@defaults, &match?({^status, nil, _retryable}, &1))

        case exact || generic do
          {_status, _code, retryable} -> retryable
          nil -> false
        end
      end
    end
    """
  end

  defp operations_source(operations) do
    entries = Enum.map_join(operations, ",\n", &operation_literal/1)

    """
    defmodule EsuissRelay.Generated.Operations do
      @moduledoc false

      alias EsuissRelay.Operation

      @operations [
        #{entries}
      ]

      @by_id Map.new(@operations, &{&1.id, &1})

      @doc false
      @spec all() :: [Operation.t()]
      def all, do: @operations

      @doc false
      @spec fetch!(atom()) :: Operation.t()
      def fetch!(id), do: Map.fetch!(@by_id, id)
    end
    """
  end

  defp operation_literal(op) do
    query =
      Enum.map_join(op.query, ", ", fn {name, kind, required} ->
        "{:#{name}, :#{kind}, #{required}}"
      end)

    path_params = Enum.map_join(op.path_params, ", ", &":#{&1}")

    "%Operation{id: :#{op.name}, method: :#{op.method}, path: #{inspect(op.path)}, " <>
      "path_params: [#{path_params}], query: [#{query}], idempotency: :#{op.idempotency}, " <>
      "if_match: :#{op.if_match}, body: :#{op.body}, content_type: #{inspect(op.content_type)}, " <>
      "paginated: #{op.paginated}, response: :#{op.response}}"
  end

  defp api_source(operations, version) do
    functions = Enum.map_join(operations, "\n\n", &function_source/1)

    """
    defmodule EsuissRelay.Api do
      @moduledoc \"\"\"
      One function for every operation of the Relay server API, version #{version}, generated
      from the OpenAPI contract by `mix esuiss_relay.gen`.

      Path parameters come first, then the request body when the operation requires one, then
      the options: query parameters and the request options of `EsuissRelay.Client`. Every
      function returns `{:ok, result}` or `{:error, error}` with an `EsuissRelay.Error`; a cursor
      list returns an `EsuissRelay.Page`.
      \"\"\"

      alias EsuissRelay.Client
      alias EsuissRelay.Generated.Operations

      #{functions}
    end
    """
  end

  defp function_source(op) do
    path_args = op.path_params
    body_args = if op.body == "required", do: ["body"], else: []
    args = ["client"] ++ path_args ++ body_args ++ ["opts \\\\ []"]

    types =
      ["Client.t()"] ++
        Enum.map(path_args, fn _name -> "String.t() | integer()" end) ++
        Enum.map(body_args, fn _name -> "map() | binary()" end) ++ ["keyword()"]

    body = if op.body == "required", do: "body", else: "nil"

    """
    @doc #{inspect(doc(op))}
    @spec #{op.name}(#{Enum.join(types, ", ")}) :: Client.result()
    def #{op.name}(#{Enum.join(args, ", ")}),
      do: Client.call(client, Operations.fetch!(:#{op.name}), [#{Enum.join(path_args, ", ")}], #{body}, opts)
    """
  end

  defp doc(op) do
    lines = [
      String.trim_trailing(op.summary, ".") <> ".",
      "`#{String.upcase(op.method)} #{op.path}`" <> if(op.paginated, do: ", returns a page.", else: "")
    ]

    lines =
      case op.query do
        [] -> lines
        query -> lines ++ ["Query: " <> Enum.map_join(query, ", ", fn {name, _, _} -> "`#{name}`" end) <> "."]
      end

    lines =
      if op.body == "optional", do: lines ++ ["The body is optional and passed as `:body`."], else: lines

    Enum.join(lines, "\n\n")
  end
end
