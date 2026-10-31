defmodule Relay.Api.Versions do
  @moduledoc """
  Dated API versions (`Relay-Version: YYYY-MM-DD`). The supported list and the latest version are the contract's `x-relay-api-versions`; the latest version is never a default, a request without the header gets its tenant's pinned version, and a tenant without one is pinned to the latest version after its first successful request. A version announced for removal carries its `Deprecation` (RFC 9745), `Sunset` (RFC 8594) and `Link rel="deprecation"` dates in the lifecycle table.

  Relay keeps one internal model, which is the latest version. A request of an older version passes through the converters of every later version in ascending order; a response passes through them in descending order (`Relay.Api.Versions.Converter`).
  """

  @versions Relay.Api.Contract.api_versions()
  @supported @versions.supported
  @latest @versions.latest
  @date ~r/\A\d{4}-\d{2}-\d{2}\z/

  @lifecycle %{}
  @converters []

  @type version :: String.t()
  @type lifecycle :: %{
          optional(version()) => %{
            deprecated_at: DateTime.t(),
            sunset_at: DateTime.t() | nil,
            link: String.t() | nil
          }
        }
  @type converters :: [{version(), module()}]

  # API-52
  @doc "The supported versions, oldest first."
  @spec supported() :: [version(), ...]
  def supported, do: @supported

  @doc "The latest version, the one a new tenant is pinned to."
  @spec latest() :: version()
  def latest, do: @latest

  # API-52
  @doc "Reads a `Relay-Version` header value; an invalid or unsupported value is `unsupported_api_version` with the supported list."
  @spec parse(String.t()) :: {:ok, version()} | {:error, Relay.Error.t()}
  def parse(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@date, value) and value in @supported do
      {:ok, value}
    else
      {:error,
       Relay.Error.new(:unsupported_api_version, "Relay-Version names no supported version", %{
         supported_versions: @supported
       })}
    end
  end

  # API-52
  @doc "The version a request is served with: the header's, else the tenant's pinned one, else the latest, which the caller pins after a successful response."
  @spec resolve(version() | nil, version() | nil) :: {version(), :header | :pinned | :pin}
  def resolve(header, _pinned) when is_binary(header), do: {header, :header}
  def resolve(nil, pinned) when is_binary(pinned), do: {pinned, :pinned}
  def resolve(nil, nil), do: {@latest, :pin}

  # API-54
  @doc "The `Deprecation`, `Sunset` and `Link` headers of a version that is announced for removal; none for a current version."
  @spec headers(version(), lifecycle()) :: [{String.t(), String.t()}]
  def headers(version, lifecycle \\ @lifecycle) do
    case Map.fetch(lifecycle, version) do
      {:ok, entry} ->
        [{"deprecation", "@" <> Integer.to_string(DateTime.to_unix(entry.deprecated_at))}] ++
          sunset(entry) ++ link(entry)

      :error ->
        []
    end
  end

  defp sunset(%{sunset_at: %DateTime{} = at}),
    do: [{"sunset", Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")}]

  defp sunset(_entry), do: []

  defp link(%{link: link}) when is_binary(link), do: [{"link", ~s(<#{link}>; rel="deprecation")}]
  defp link(_entry), do: []

  # API-54
  @doc "Converts a request body of `version` into the internal model."
  @spec request(version(), String.t(), term(), converters()) :: term()
  def request(version, operation_id, body, converters \\ @converters) do
    converters
    |> chain(version)
    |> Enum.reduce(body, fn module, acc -> module.request(operation_id, acc) end)
  end

  # API-54
  @doc "Converts a response body of the internal model into `version`."
  @spec response(version(), String.t(), term(), converters()) :: term()
  def response(version, operation_id, body, converters \\ @converters) do
    converters
    |> chain(version)
    |> Enum.reverse()
    |> Enum.reduce(body, fn module, acc -> module.response(operation_id, acc) end)
  end

  # API-54
  @doc "The converters between `version` and the internal model, oldest first: every converter of `version` or later."
  @spec chain(converters(), version()) :: [module()]
  def chain(converters, version) do
    for {from, module} <- Enum.sort_by(converters, &elem(&1, 0)), from >= version, do: module
  end
end
