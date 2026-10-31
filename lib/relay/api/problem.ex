defmodule Relay.Api.Problem do
  @moduledoc """
  RFC 9457 problem documents built from an API error. The error's code names a catalog entry (`Relay.Api.ErrorCatalog`); its message becomes `detail` and its details carry the extensions. `type`, `title`, `status`, `code` and `retryable` are always present, `type` resolves on the region's base URL and is never `about:blank`, and a retryable problem always carries `retry_after` with the same value as its `Retry-After` header.
  """

  alias Relay.Api.ErrorCatalog

  @extensions ~w(errors limit actual limit_name required_scope granted_scopes policy quota)a
  @role_extensions ~w(supported_versions required_role granted_roles step_up error)a
  @field_keys ~w(pointer code detail limit actual)a

  @type context :: %{base_url: String.t(), instance: String.t(), request_id: String.t() | nil}
  @type t :: {400..599, [{String.t(), String.t()}], map()}

  # API-36
  # API-37
  # API-38
  # API-73
  @doc "Builds the status, the extra response headers and the body of a problem for an API error whose code is in the catalog."
  @spec build(Relay.Error.t(), context()) :: t()
  def build(%Relay.Error{code: code, message: message, details: details}, context) do
    entry =
      case ErrorCatalog.fetch(code) do
        {:ok, entry} -> entry
        :error -> raise ArgumentError, "#{inspect(code)} is not in the error catalog"
      end

    retry_after = if entry.retryable, do: retry_after(entry, details)

    body =
      %{
        "type" => ErrorCatalog.type_url(context.base_url, entry.code),
        "title" => entry.title,
        "status" => entry.status,
        "code" => entry.code,
        "retryable" => entry.retryable,
        "instance" => context.instance
      }
      |> put("detail", message)
      |> put("request_id", context[:request_id])
      |> put("retry_after", retry_after)
      |> Map.merge(extensions(details))

    headers = if retry_after, do: [{"retry-after", Integer.to_string(retry_after)}], else: []
    {entry.status, headers, body}
  end

  # API-38
  @doc "The `Retry-After` seconds of a retryable entry: the error's own value, else the catalog rule (the lower bound of a range)."
  @spec retry_after(ErrorCatalog.entry(), map()) :: pos_integer()
  def retry_after(entry, details) do
    case Map.get(details, :retry_after) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> entry.retry_after.seconds || 1
    end
  end

  defp extensions(details) do
    for key <- @extensions ++ @role_extensions,
        value = Map.get(details, key),
        value not in [nil, []],
        into: %{},
        do: {Atom.to_string(key), extension(key, value)}
  end

  defp extension(:errors, errors), do: Enum.map(errors, &field_error/1)
  defp extension(_key, value), do: value

  defp field_error(error) do
    for key <- @field_keys,
        value = Map.get(error, key, Map.get(error, Atom.to_string(key))),
        value != nil,
        into: %{},
        do: {Atom.to_string(key), value}
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
