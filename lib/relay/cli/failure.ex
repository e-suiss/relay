defmodule Relay.CLI.Failure do
  @moduledoc """
  A failed command: its exit code kind, a machine-readable code (the problem `code` of a Relay answer, or a code of the tool itself), a message and, for an HTTP answer, its status, request id and decoded body.
  """

  alias Relay.CLI.ExitCode

  @enforce_keys [:kind, :code, :message]
  defstruct [:kind, :code, :message, :status, :request_id, :response]

  @type t :: %__MODULE__{
          kind: ExitCode.kind(),
          code: String.t(),
          message: String.t(),
          status: integer() | nil,
          request_id: String.t() | nil,
          response: term()
        }

  # X-42
  @doc "Builds a failure of the tool itself."
  @spec new(ExitCode.kind(), String.t(), String.t()) :: t()
  def new(kind, code, message) when is_binary(code) and is_binary(message),
    do: %__MODULE__{kind: kind, code: code, message: message}

  # X-42
  @doc "Builds the failure of an HTTP answer that is not 2xx from its RFC 9457 problem, or from its status when the body is not a problem."
  @spec from_response(%{status: integer(), headers: map(), body: term()}) :: t()
  def from_response(%{status: status, headers: headers, body: body}) do
    problem = if problem?(body), do: body

    %__MODULE__{
      kind: ExitCode.for_status(status),
      code: code(problem, status),
      message: message(problem, status),
      status: status,
      request_id: request_id(problem, headers),
      response: if(body in [nil, ""], do: nil, else: body)
    }
  end

  @doc "The failure as a JSON-ready map; a problem body is under `problem`, any other body under `response`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = failure) do
    body_key = if problem?(failure.response), do: "problem", else: "response"

    %{
      "kind" => Atom.to_string(failure.kind),
      "code" => failure.code,
      "message" => failure.message
    }
    |> put("status", failure.status)
    |> put("request_id", failure.request_id)
    |> put(body_key, failure.response)
  end

  @doc "Readable lines of the failure: the code and message, field errors and the request id."
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{} = failure) do
    errors =
      case failure.response do
        %{"errors" => errors} when is_list(errors) -> Enum.map(errors, &field_line/1)
        _ -> []
      end

    request = if failure.request_id, do: ["  request id: " <> failure.request_id], else: []
    ["error: #{failure.code}: #{failure.message}" | errors] ++ request
  end

  defp field_line(%{} = error),
    do: "  #{error["pointer"]}: #{error["code"]}#{detail(error["detail"])}"

  defp field_line(other), do: "  #{inspect(other)}"

  defp detail(text) when is_binary(text), do: " (" <> text <> ")"
  defp detail(_text), do: ""

  defp problem?(%{"code" => code}) when is_binary(code), do: true
  defp problem?(_body), do: false

  defp code(%{"code" => code}, _status), do: code
  defp code(nil, status), do: "http_#{status}"

  defp message(%{"detail" => detail}, _status) when is_binary(detail), do: detail
  defp message(%{"title" => title}, _status) when is_binary(title), do: title
  defp message(_problem, status), do: "Relay answered HTTP #{status}"

  defp request_id(%{"request_id" => id}, _headers) when is_binary(id), do: id

  defp request_id(_problem, headers) do
    case Map.get(headers, "request-id") do
      [id | _] when is_binary(id) -> id
      _ -> nil
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
