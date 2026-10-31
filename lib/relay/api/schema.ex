defmodule Relay.Api.Schema do
  @moduledoc """
  JSON Schema 2020-12 validation of request bodies against the contract. The contract's schema documents are folded into one `$defs` table with their references rewritten (`./components/schemas.yaml#/Name` becomes `#/$defs/schemas.Name`), so a request or response schema builds into one self-contained root. Request roots are built once, on first use, and published together.

  Every error is reported, not only the first (API-37), as an RFC 6901 pointer and a field error subcode. A property that the schema does not declare is an unknown field (`not_allowed`): when any is found the problem is `unknown_field`, otherwise `validation_failed` (API-8).
  """

  alias Relay.Api.Contract

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @schema_files ~w(schemas problem)
  @key {__MODULE__, :requests}
  @too_long [:maxLength, :maxItems, :maxProperties, :maximum, :exclusiveMaximum]
  @too_short [:minLength, :minItems, :minProperties, :minimum, :exclusiveMinimum]

  rewrite = fn rewrite, value, file ->
    case value do
      %{"$ref" => ref} = map when is_binary(ref) ->
        target =
          case ref do
            "#/" <> pointer ->
              "#/$defs/" <> file <> "." <> pointer

            "./components/" <> rest ->
              [doc, pointer] = String.split(rest, ".yaml#/", parts: 2)
              "#/$defs/" <> doc <> "." <> pointer

            "./" <> rest ->
              [doc, pointer] = String.split(rest, ".yaml#/", parts: 2)
              "#/$defs/" <> doc <> "." <> pointer
          end

        map
        |> Map.delete("$ref")
        |> Map.new(fn {k, v} -> {k, rewrite.(rewrite, v, file)} end)
        |> Map.put("$ref", target)

      map when is_map(map) ->
        Map.new(map, fn {k, v} -> {k, rewrite.(rewrite, v, file)} end)

      list when is_list(list) ->
        Enum.map(list, &rewrite.(rewrite, &1, file))

      other ->
        other
    end
  end

  defs =
    for name <- @schema_files,
        {schema_name, schema} <- Contract.documents()[name],
        is_map(schema),
        into: %{} do
      {name <> "." <> schema_name, rewrite.(rewrite, schema, name)}
    end

  requests =
    for op <- Contract.operations(),
        {type, schema} <- op.request,
        is_map(schema),
        into: %{} do
      {{op.id, type}, rewrite.(rewrite, schema, "server")}
    end

  responses =
    for op <- Contract.operations(),
        {status, content} <- op.responses,
        {type, schema} <- content,
        is_map(schema),
        into: %{} do
      {{op.id, status, type}, rewrite.(rewrite, schema, "server")}
    end

  @defs defs
  @requests requests
  @responses responses

  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}

  # API-2
  @doc "Builds a root for a schema written in `server.yaml` (or already rewritten), with the contract's `$defs`."
  @spec build(map()) :: JSV.Root.t()
  def build(schema) when is_map(schema),
    do: JSV.build!(Map.merge(schema, %{"$defs" => @defs}), default_meta: @dialect)

  # API-2
  @doc "The rewritten response schema of an operation, status and content type, or `nil` when the contract has none."
  @spec response_schema(String.t(), String.t(), String.t()) :: map() | nil
  def response_schema(operation_id, status, content_type),
    do: Map.get(@responses, {operation_id, status, content_type})

  # API-8
  @doc "Whether the operation accepts a request body of this media type."
  @spec request?(String.t(), String.t()) :: boolean()
  def request?(operation_id, content_type),
    do: Map.has_key?(@requests, {operation_id, content_type})

  # API-8
  # API-37
  @doc "Validates a decoded request body against the operation's schema for the media type."
  @spec validate_request(String.t(), String.t(), term()) :: :ok | {:error, Relay.Error.t()}
  def validate_request(operation_id, content_type, body) do
    case Map.fetch(requests(), {operation_id, content_type}) do
      {:ok, root} -> validate(root, body)
      :error -> :ok
    end
  end

  # API-37
  @doc "Validates a value against a root and maps every failure to a field error."
  @spec validate(JSV.Root.t(), term()) :: :ok | {:error, Relay.Error.t()}
  def validate(root, value) do
    case JSV.validate(value, root, cast: false) do
      {:ok, _value} ->
        :ok

      {:error, error} ->
        errors =
          error
          |> JSV.normalize_error(keys: :atoms, min_error_level: JSV.ErrorFormatter.level_cause())
          |> Map.fetch!(:details)
          |> Enum.flat_map(&unit/1)
          |> Enum.uniq_by(&{&1.pointer, &1.code})
          |> Enum.sort_by(& &1.pointer)

        {:error, problem(errors)}
    end
  end

  defp problem(errors) do
    if Enum.any?(errors, &(&1.code == "not_allowed")) do
      Relay.Error.new(:unknown_field, "the body has fields the schema does not declare", %{
        errors: errors
      })
    else
      Relay.Error.new(:validation_failed, "the body does not match the schema", %{errors: errors})
    end
  end

  defp requests do
    case :persistent_term.get(@key, nil) do
      nil ->
        built = Map.new(@requests, fn {key, schema} -> {key, build(schema)} end)
        :persistent_term.put(@key, built)
        built

      built ->
        built
    end
  end

  defp unit(%{instanceLocation: location} = unit) do
    at = %{pointer: pointer(location), eval: Map.get(unit, :evaluationPath, "#")}
    Enum.flat_map(Map.get(unit, :errors, []), &keyword(&1, at))
  end

  defp keyword(%{kind: :required} = error, at) do
    for name <- get_in(error, [:ctx, :missing]) || [],
        do: field(at.pointer <> "/" <> escape(name), "required", "the field is required")
  end

  defp keyword(%{kind: :additionalProperties, ctx: %{property: name}}, at) do
    [field(at.pointer <> "/" <> escape(name), "not_allowed", "the field is not in the schema")]
  end

  defp keyword(%{kind: kind} = error, at) when kind in [:oneOf, :anyOf] do
    prefix = at.eval <> "/" <> Atom.to_string(kind) <> "/"

    case branch(Map.get(error, :details, []), at, prefix) do
      {:ok, errors} -> errors
      :none -> [field(at.pointer, "invalid_format", error.message)]
    end
  end

  defp keyword(%{kind: kind, message: message}, at), do: [field(at.pointer, code(kind), message)]

  defp branch(units, at, prefix) do
    units
    |> Enum.group_by(&branch_index(Map.get(&1, :evaluationPath, ""), prefix))
    |> Map.values()
    |> Enum.map(fn branch_units -> Enum.flat_map(branch_units, &unit/1) end)
    |> Enum.reject(fn errors -> Enum.any?(errors, &(&1.pointer == at.pointer)) end)
    |> case do
      [errors] -> {:ok, errors}
      _ -> :none
    end
  end

  defp branch_index(path, prefix) do
    case String.split(path, prefix, parts: 2) do
      [_, rest] -> rest |> String.split("/", parts: 2) |> hd()
      [_] -> path
    end
  end

  defp code(kind) when kind in @too_long, do: "too_long"
  defp code(kind) when kind in @too_short, do: "too_short"

  defp code(kind) when kind in [:enum, :const], do: "unsupported_value"
  defp code(:uniqueItems), do: "conflict"
  defp code(_kind), do: "invalid_format"

  defp field(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp pointer("#" <> rest), do: rest
  defp pointer(other), do: other

  defp escape(name), do: name |> String.replace("~", "~0") |> String.replace("/", "~1")
end
