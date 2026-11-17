defmodule Relay.Api.Mcp do
  @moduledoc """
  The Model Context Protocol face of the server API (AG-43, E-52): the tool catalogue, read at compile time from `contracts/mcp/tools.yaml`, and the JSON-RPC rules of the stateless protocol revision the catalogue names. The server offers tool calls and nothing else: `server/discover`, `tools/list` and `tools/call`. It keeps no session, opens no stream and asks the client for nothing, so it uses neither sampling nor elicitation and never answers `input_required`.

  A tool is one operation of the API contract (`Relay.Api.Contract`). Its input is the operation's path parameters, its query parameters, its request body under `body` and, for an idempotent operation, the key under `idempotency_key`; the web layer runs the operation itself, so a tool call is checked, limited, decided and recorded exactly as the HTTP request is. The catalogue a caller sees holds the tools whose operation one of its scopes grants (`catalogue/1`); a call to another tool is refused by the operation's own scope rule. No tool answers a waitpoint (AG-45, E-54): a response reaches Relay from a responder's channel, never from the waiter's protocol.

  A waitpoint in a result carries, under `_meta`, the state the MCP tasks extension gives it in the protocol mapping table (`input_required` while a question or a review is open), so a client that tracks a task reads the waitpoint as that task's state.
  """

  alias Relay.Api.Contract

  @path Path.expand("../../../contracts/mcp/tools.yaml", __DIR__)
  @external_resource @path
  @document YamlElixir.read_from_file!(@path)

  @protocol_key "io.modelcontextprotocol/protocolVersion"
  @server_key "io.modelcontextprotocol/serverInfo"
  @task_key "relay.esuiss/task"
  @methods ["server/discover", "tools/list", "tools/call"]
  @sentinel ~r/\A=\?base64\?(.*)\?=\z/s
  @key_schema %{"type" => "string", "minLength" => 8, "maxLength" => 255}
  @path_schema %{"type" => "string", "minLength" => 1, "maxLength" => 256}

  @type tool :: %{
          name: String.t(),
          operation: String.t(),
          path: [String.t()],
          query: %{String.t() => map()},
          fixed_query: %{String.t() => String.t()},
          body: boolean(),
          body_required: boolean(),
          idempotent: boolean(),
          descriptor: map()
        }
  @type request :: %{id: String.t() | integer() | nil, method: String.t(), params: map()}
  @type refusal :: %{
          status: 400 | 404,
          id: term(),
          code: integer(),
          message: String.t(),
          data: map() | nil
        }

  schemas = Contract.documents()["schemas"]

  refs = fn refs, value ->
    case value do
      %{"$ref" => "./components/schemas.yaml#/" <> name} -> [name]
      %{"$ref" => "#/" <> name} -> [name]
      %{} = map -> Enum.flat_map(Map.values(map), &refs.(refs, &1))
      list when is_list(list) -> Enum.flat_map(list, &refs.(refs, &1))
      _other -> []
    end
  end

  closure = fn closure, names, seen ->
    case Enum.uniq(names) -- seen do
      [] ->
        seen

      fresh ->
        next = Enum.flat_map(fresh, &refs.(refs, Map.fetch!(schemas, &1)))
        closure.(closure, next, seen ++ fresh)
    end
  end

  local = fn local, value ->
    case value do
      %{"$ref" => "./components/schemas.yaml#/" <> name} = map ->
        Map.put(map, "$ref", "#/$defs/" <> name)

      %{"$ref" => "#/" <> name} = map ->
        Map.put(map, "$ref", "#/$defs/" <> name)

      %{} = map ->
        Map.new(map, fn {key, inner} -> {key, local.(local, inner)} end)

      list when is_list(list) ->
        Enum.map(list, &local.(local, &1))

      other ->
        other
    end
  end

  tools =
    for raw <- @document["tools"] do
      operation = Contract.operation!(raw["operation"])
      body = Map.get(operation.request, "application/json")
      idempotent = operation.idempotency in [:required, :derived]
      path = raw["path"]
      query = raw["query"]

      properties =
        path
        |> Map.new(&{&1, @path_schema})
        |> Map.merge(query)
        |> Map.merge(if(body, do: %{"body" => local.(local, body)}, else: %{}))
        |> Map.merge(if(idempotent, do: %{"idempotency_key" => @key_schema}, else: %{}))

      required =
        path ++
          if(body && operation.request_required, do: ["body"], else: []) ++
          if(idempotent, do: ["idempotency_key"], else: [])

      names = closure.(closure, refs.(refs, body || %{}), [])
      defs = Map.new(names, &{&1, local.(local, Map.fetch!(schemas, &1))})

      input =
        %{"type" => "object", "properties" => properties, "additionalProperties" => false}
        |> Map.merge(if(required == [], do: %{}, else: %{"required" => required}))
        |> Map.merge(if(defs == %{}, do: %{}, else: %{"$defs" => defs}))

      %{
        name: raw["name"],
        operation: operation.id,
        path: path,
        query: query,
        fixed_query: raw["fixed_query"],
        body: is_map(body),
        body_required: is_map(body) and operation.request_required,
        idempotent: idempotent,
        descriptor: %{
          "name" => raw["name"],
          "title" => raw["title"],
          "description" => raw["description"],
          "inputSchema" => input,
          "annotations" => raw["annotations"]
        }
      }
    end

  @tools tools
  @by_name Map.new(tools, &{&1.name, &1})
  @versions @document["protocol"]["versions"]
  @server @document["server"]
  @cache @document["cache"]

  # AG-43
  @doc "The protocol revisions the server serves."
  @spec versions() :: [String.t(), ...]
  def versions, do: @versions

  # AG-43
  @doc "Every tool of the catalogue, in the order of the contract."
  @spec tools() :: [tool(), ...]
  def tools, do: @tools

  # AG-43
  @doc "The tool with this name."
  @spec tool(term()) :: {:ok, tool()} | :error
  def tool(name), do: Map.fetch(@by_name, name)

  # AG-43
  # E-52
  @doc "True when one of `scopes` grants the operation of the tool: the scope rule of the HTTP operation."
  @spec granted?(tool(), [String.t()]) :: boolean()
  def granted?(%{operation: id}, scopes) when is_list(scopes) do
    case Contract.operation!(id).scopes do
      [] -> true
      accepted -> Enum.any?(accepted, &(&1 in scopes))
    end
  end

  # AG-43
  @doc "The catalogue of a caller: the tools its scopes grant, in the order of the contract."
  @spec catalogue([String.t()]) :: [tool()]
  def catalogue(scopes), do: Enum.filter(@tools, &granted?(&1, scopes))

  # AG-43
  @doc "Reads a decoded JSON-RPC request with the request's headers: the protocol version, the method and the tool name must be the same in the headers and in the body, the version one the server serves and the method one it has. A request without an id is a notification."
  @spec request(map(), [{String.t(), String.t()}]) :: {:ok, request()} | {:error, refusal()}
  def request(%{"method" => method} = body, headers) when is_binary(method) do
    id = Map.get(body, "id")
    params = Map.get(body, "params") || %{}

    with :ok <- versioned(id, get_in(params, ["_meta", @protocol_key]), headers),
         :ok <- routed(id, method, params, headers),
         do: {:ok, %{id: id, method: method, params: params}}
  end

  def request(body, _headers) when is_map(body),
    do: {:error, refusal(400, Map.get(body, "id"), -32_600, "Invalid Request", nil)}

  defp versioned(id, version, headers) do
    case header(headers, "mcp-protocol-version") do
      nil ->
        mismatch(id, "the MCP-Protocol-Version header is missing")

      ^version ->
        if version in @versions, do: :ok, else: unsupported(id, version)

      _other ->
        mismatch(id, "the MCP-Protocol-Version header does not match the body")
    end
  end

  defp routed(id, method, params, headers) do
    cond do
      header(headers, "mcp-method") != method ->
        mismatch(id, "the Mcp-Method header does not match the body")

      method not in @methods ->
        {:error, refusal(404, id, -32_601, "Method not found", nil)}

      method == "tools/call" and name(headers) != Map.get(params, "name") ->
        mismatch(id, "the Mcp-Name header does not match the body")

      true ->
        :ok
    end
  end

  defp unsupported(id, version) do
    data = %{"supported" => @versions, "requested" => version}
    {:error, refusal(400, id, -32_022, "Unsupported protocol version", data)}
  end

  defp mismatch(id, detail),
    do: {:error, refusal(400, id, -32_020, "Header mismatch: " <> detail, nil)}

  defp refusal(status, id, code, message, data),
    do: %{status: status, id: id, code: code, message: message, data: data}

  defp header(headers, name) do
    case for {^name, value} <- headers, do: value do
      [value] -> value
      _none_or_many -> nil
    end
  end

  defp name(headers) do
    case header(headers, "mcp-name") do
      nil -> nil
      value -> decoded(value, Regex.run(@sentinel, value))
    end
  end

  defp decoded(value, nil), do: value

  defp decoded(_value, [_all, encoded]) do
    case Base.decode64(encoded) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  # AG-43
  @doc "The result of `server/discover`: the served revisions and the one capability, tools."
  @spec discover() :: map()
  def discover do
    %{
      "resultType" => "complete",
      "supportedVersions" => @versions,
      "capabilities" => %{"tools" => %{}},
      "instructions" => @server["instructions"],
      "ttlMs" => @cache["discover_ttl_ms"],
      "cacheScope" => "public",
      "_meta" => server_meta()
    }
  end

  # AG-43
  # E-52
  @doc "The result of `tools/list` for a caller's scopes; it differs by credential, so it is cached privately."
  @spec list([String.t()]) :: map()
  def list(scopes) do
    %{
      "resultType" => "complete",
      "tools" => Enum.map(catalogue(scopes), & &1.descriptor),
      "ttlMs" => @cache["tools_ttl_ms"],
      "cacheScope" => "private",
      "_meta" => server_meta()
    }
  end

  # AG-43
  # AG-45
  # AG-46
  @doc "The result of `tools/call` from the answer of the tool's operation: the body as structured content and as text, an error when the status is not a success, and the task state of a waitpoint in the body."
  @spec result(100..599, term()) :: map()
  def result(status, body) do
    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => Jason.encode!(body)}],
      "structuredContent" => body,
      "isError" => status not in 200..299,
      "_meta" => Map.merge(server_meta(), task(body))
    }
  end

  # AG-43
  # AG-46
  defp task(%{"object" => "waitpoint", "id" => id, "state" => state} = waitpoint) do
    view = %{state: state, kind: waitpoint["kind"], profile: waitpoint["profile"]}

    case Relay.Agents.protocol_state(:mcp_tasks, view) do
      {:ok, %{rule: rule, state: task_state}} ->
        task = %{"taskId" => id, "rule" => Atom.to_string(rule)}
        %{@task_key => if(task_state, do: Map.put(task, "status", task_state), else: task)}

      :error ->
        %{}
    end
  end

  defp task(_body), do: %{}

  defp server_meta,
    do: %{@server_key => %{"name" => @server["name"], "title" => @server["title"]}}

  # AG-43
  @doc "A JSON-RPC response carrying a result."
  @spec response(term(), map()) :: map()
  def response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  # AG-43
  @doc "A JSON-RPC response carrying an error."
  @spec error(term(), integer(), String.t(), map() | nil) :: map()
  def error(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_map(data), do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  # AG-43
  @doc "Reads the arguments of a call into the parts of the tool's operation: its path parameters, its query, its body and its idempotency key; `{:error, detail}` names what does not fit."
  @spec arguments(tool(), term()) ::
          {:ok, %{path: map(), query: map(), body: term(), key: [String.t()]}}
          | {:error, String.t()}
  def arguments(tool, arguments) when is_map(arguments) do
    known = tool.path ++ Map.keys(tool.query) ++ ["body", "idempotency_key"]

    cond do
      Map.keys(arguments) -- known != [] ->
        {:error, "unknown argument: " <> Enum.join(Map.keys(arguments) -- known, ", ")}

      not Enum.all?(tool.path, &text?(arguments[&1])) ->
        {:error, "missing argument: " <> Enum.join(tool.path, ", ")}

      not Enum.all?(Map.keys(tool.query), &scalar?(Map.get(arguments, &1))) ->
        {:error, "a query argument is a string, an integer or a boolean"}

      tool.body_required and not is_map_key(arguments, "body") ->
        {:error, "missing argument: body"}

      not tool.body and is_map_key(arguments, "body") ->
        {:error, "this tool takes no body"}

      true ->
        {:ok,
         %{
           path: Map.take(arguments, tool.path),
           query: query(tool, arguments),
           body: Map.get(arguments, "body"),
           key: key(arguments)
         }}
    end
  end

  def arguments(_tool, _other), do: {:error, "arguments is an object"}

  defp text?(value), do: is_binary(value) and value != ""

  defp scalar?(value),
    do: is_nil(value) or is_binary(value) or is_integer(value) or is_boolean(value)

  defp query(tool, arguments) do
    given =
      for {name, _schema} <- tool.query, is_map_key(arguments, name), into: %{} do
        {name, to_string(arguments[name])}
      end

    Map.merge(given, tool.fixed_query)
  end

  defp key(%{"idempotency_key" => key}) when is_binary(key), do: [key]
  defp key(_arguments), do: []
end
