defmodule Relay.Api.Contract do
  @moduledoc """
  The server API contract, read at compile time from `contracts/openapi/server.yaml` and its components. It answers which operations exist, what each one requires (scopes, weight, idempotency, environment) and which schemas its requests and responses follow. The contract files are the single source; nothing here repeats their values.
  """

  @root Path.expand("../../../contracts/openapi", __DIR__)
  @files %{
    "server" => "server.yaml",
    "schemas" => "components/schemas.yaml",
    "problem" => "components/problem.yaml",
    "parameters" => "components/parameters.yaml",
    "headers" => "components/headers.yaml",
    "responses" => "components/responses.yaml"
  }

  for {_name, file} <- @files, do: @external_resource(Path.join(@root, file))

  documents =
    Map.new(@files, fn {name, file} ->
      {name, YamlElixir.read_from_file!(Path.join(@root, file))}
    end)

  @documents documents

  @methods ~w(get post put patch delete)

  @type operation :: %{
          id: String.t(),
          method: String.t(),
          path: String.t(),
          endpoint: String.t(),
          scopes: [String.t()],
          public: boolean(),
          weight: non_neg_integer() | :rows,
          idempotency: :required | :derived | :not_applicable,
          environment: :test | nil,
          errors: [String.t()],
          request: %{optional(String.t()) => map()},
          responses: %{optional(String.t()) => %{optional(String.t()) => map() | nil}}
        }

  @doc "The raw contract documents by name: `server` and the component files."
  @spec documents() :: %{String.t() => map()}
  def documents, do: @documents

  resolve_response = fn
    %{"$ref" => "./components/responses.yaml#/" <> name} ->
      Map.fetch!(@documents["responses"], name)

    response ->
      response
  end

  operations =
    for {path, item} <- @documents["server"]["paths"],
        {method, op} <- item,
        method in @methods do
      responses =
        Map.new(op["responses"], fn {status, response} ->
          content = resolve_response.(response)["content"] || %{}
          {to_string(status), Map.new(content, fn {type, media} -> {type, media["schema"]} end)}
        end)

      request =
        case op["requestBody"] do
          %{"content" => content} -> Map.new(content, fn {type, m} -> {type, m["schema"]} end)
          nil -> %{}
        end

      weight =
        case op["x-relay-weight"] do
          "rows" -> :rows
          weight when is_integer(weight) -> weight
        end

      idempotency =
        case op["x-relay-idempotency"] do
          "required" -> :required
          "derived" -> :derived
          "not_applicable" -> :not_applicable
        end

      %{
        id: op["operationId"],
        method: String.upcase(method),
        path: path,
        endpoint: String.upcase(method) <> " " <> path,
        scopes: op["x-relay-scopes"] || [],
        public: op["security"] == [],
        weight: weight,
        idempotency: idempotency,
        environment: if(op["x-relay-environment"] == "test", do: :test),
        errors: op["x-relay-errors"] || [],
        request: request,
        responses: responses
      }
    end

  @operations Map.new(operations, &{&1.id, &1})
  @limits @documents["server"]["x-relay-limits"]
  @api_versions @documents["server"]["x-relay-api-versions"]

  # API-1
  # API-2
  @doc "Every operation of the server contract."
  @spec operations() :: [operation()]
  def operations, do: Map.values(@operations)

  @doc "The operation with this `operationId`."
  @spec operation(String.t()) :: {:ok, operation()} | :error
  def operation(id), do: Map.fetch(@operations, id)

  @doc "The operation with this `operationId`; raises for an unknown one."
  @spec operation!(String.t()) :: operation()
  def operation!(id), do: Map.fetch!(@operations, id)

  # API-4
  # API-77
  @doc "The contract's limits (`x-relay-limits`): the values of the limits page."
  @spec limits() :: map()
  def limits, do: @limits

  # API-52
  @doc "The contract's dated API versions (`x-relay-api-versions`)."
  @spec api_versions() :: %{supported: [String.t(), ...], latest: String.t()}
  def api_versions,
    do: %{supported: @api_versions["supported"], latest: @api_versions["latest"]}
end
