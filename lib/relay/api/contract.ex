defmodule Relay.Api.Contract do
  @moduledoc """
  The API contract, read at compile time from `contracts/openapi/server.yaml`, `contracts/openapi/subscriber.yaml`, `contracts/openapi/operator.yaml` and their components. It answers which operations exist, which family each belongs to (`:server`, `:subscriber` or `:operator`), how it is authenticated (`:bearer`, `:public` or `:webhook`), what it requires (scopes, weight, idempotency, environment; for an operator operation the lowest role and the step-up rule) and which schemas its requests and responses follow. A subscriber or operator operation's local schema references are inlined. The contract files are the single source; nothing here repeats their values.
  """

  @root Path.expand("../../../contracts/openapi", __DIR__)
  @files %{
    "server" => "server.yaml",
    "subscriber" => "subscriber.yaml",
    "operator" => "operator.yaml",
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
          family: :server | :subscriber | :operator,
          role: :installation_operator | :tenant_admin | :tenant_operator | nil,
          step_up: :always | :conditional | :never,
          stored_replay: boolean(),
          security: :bearer | :public | :webhook,
          no_store: boolean(),
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
          request_required: boolean(),
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

  inline = fn inline, value, local ->
    case value do
      %{"$ref" => "#/components/schemas/" <> name} ->
        inline.(inline, Map.fetch!(local, name), local)

      map when is_map(map) ->
        Map.new(map, fn {k, v} -> {k, inline.(inline, v, local)} end)

      list when is_list(list) ->
        Enum.map(list, &inline.(inline, &1, local))

      other ->
        other
    end
  end

  roles = %{
    "installation_operator" => :installation_operator,
    "tenant_admin" => :tenant_admin,
    "tenant_operator" => :tenant_operator
  }

  families = [
    server: @documents["server"],
    subscriber: @documents["subscriber"],
    operator: @documents["operator"]
  ]

  operations =
    for {family, document} <- families,
        {path, item} <- document["paths"],
        {method, raw} <- item,
        method in @methods do
      op = inline.(inline, raw, get_in(document, ["components", "schemas"]) || %{})

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
          "none" -> :not_applicable
        end

      security =
        case op["security"] do
          [] -> :public
          [%{"suiss_webhook_signature" => _} | _] -> :webhook
          _bearer -> :bearer
        end

      %{
        id: op["operationId"],
        family: family,
        security: security,
        no_store: get_in(op, ["responses", "200", "headers", "Cache-Control"]) != nil,
        method: String.upcase(method),
        path: path,
        endpoint: String.upcase(method) <> " " <> path,
        scopes: op["x-relay-scopes"] || [],
        public: security == :public,
        weight: weight,
        idempotency: idempotency,
        environment: if(op["x-relay-environment"] == "test", do: :test),
        role: Map.get(roles, op["x-relay-role"]),
        step_up:
          case op["x-relay-step-up"] do
            "always" -> :always
            "conditional" -> :conditional
            _ -> :never
          end,
        stored_replay: op["x-relay-idempotency-replay"] != "not_stored",
        errors: op["x-relay-errors"] || [],
        request: request,
        request_required: get_in(op, ["requestBody", "required"]) == true,
        responses: responses
      }
    end

  @operations Map.new(operations, &{&1.id, &1})
  @api_versions @documents["server"]["x-relay-api-versions"]

  # API-1
  # API-2
  @doc "Every operation of the server, subscriber and operator contracts."
  @spec operations() :: [operation()]
  def operations, do: Map.values(@operations)

  # API-78
  @doc "Every operation of one contract family."
  @spec operations(:server | :subscriber | :operator) :: [operation()]
  def operations(family), do: Enum.filter(operations(), &(&1.family == family))

  @doc "The operation with this `operationId`."
  @spec operation(String.t()) :: {:ok, operation()} | :error
  def operation(id), do: Map.fetch(@operations, id)

  @doc "The operation with this `operationId`; raises for an unknown one."
  @spec operation!(String.t()) :: operation()
  def operation!(id), do: Map.fetch!(@operations, id)

  # API-4
  # API-77
  @doc "The contract's limits (`x-relay-limits`): the values of the limits page; see `Relay.Limits`."
  @spec limits() :: map()
  defdelegate limits(), to: Relay.Limits, as: :all

  # API-52
  @doc "The contract's dated API versions (`x-relay-api-versions`)."
  @spec api_versions() :: %{supported: [String.t(), ...], latest: String.t()}
  def api_versions,
    do: %{supported: @api_versions["supported"], latest: @api_versions["latest"]}
end
