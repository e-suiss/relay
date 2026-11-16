defmodule Relay.Api.RealtimeOrigins do
  @moduledoc """
  The browser origins of a tenant environment that may open a realtime connection (IN-54): the WebSocket and the SSE stream a browser opens send an `Origin` header, which must equal one of these origins exactly; there are no wildcards. A client that sends no `Origin` (a mobile app, a server) is not affected. The list is held per tenant × environment as the setting `realtime.allowed_origins` and replaced whole through the server API; a change is audited as `setting.changed`.

  An origin is `https://` followed by a lowercase host name and an optional port other than 443, with no path, query or trailing slash, at most the contract's `realtime.origin_max_bytes`; only the `test` environment also accepts `http://localhost` with an optional port other than 80. A list holds at most the contract's `realtime.allowed_origins_max` origins, each once. An empty list leaves no browser origin allowed.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Store
  alias Relay.TemplateStore

  @key "realtime.allowed_origins"
  @max Relay.Limits.fetch!(["realtime", "allowed_origins_max"])
  @bytes Relay.Limits.fetch!(["realtime", "origin_max_bytes"])
  @https ~r/\Ahttps:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*(?::([1-9][0-9]{0,4}))?\z/
  @localhost ~r/\Ahttp:\/\/localhost(?::([1-9][0-9]{0,4}))?\z/

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @doc "The setting key of the list."
  @spec key() :: String.t()
  def key, do: @key

  # IN-54
  @doc "The API view of a list."
  @spec view([String.t()]) :: map()
  def view(origins), do: %{"object" => "realtime_origins", "origins" => origins}

  # IN-54
  @doc "Reads the list of the scope."
  @spec get(Relay.Scope.t()) :: answer()
  def get(scope) do
    case Store.in_scope(scope, fn _status -> Store.realtime_origins() end) do
      {:ok, origins} -> {:ok, {200, [], view(origins)}}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # IN-54
  @doc "Replaces the list inside the request's transaction; every origin that breaks a rule is a field error."
  @spec put(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def put(scope, %{"origins" => origins}, actor) when is_list(origins) do
    case errors(scope.environment, origins) do
      [] ->
        digest = Gate.digest(scope, "setting.changed", @key)
        stored = if origins == [], do: nil, else: origins
        _written = TemplateStore.tenant_setting_put(@key, stored, digest, actor)
        {:ok, {200, [], view(origins)}}

      errors ->
        message = "the origins break a field rule"
        {:error, Relay.Error.new(:validation_failed, message, %{errors: errors})}
    end
  end

  def put(_scope, _body, _actor) do
    detail = "origins is a list of origins"

    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: "/origins", code: "required", detail: detail}]
     })}
  end

  # IN-54
  @doc "The field errors of a list for `environment`: too many origins, an origin that is not one, or one named twice."
  @spec errors(Relay.Environment.t(), [term()]) :: [map()]
  def errors(environment, origins) when is_list(origins) do
    count =
      if length(origins) > @max,
        do: [error("/origins", "too_long", "at most #{@max} origins")],
        else: []

    {_seen, each} =
      origins
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {origin, index}, {seen, acc} ->
        pointer = "/origins/#{index}"
        {MapSet.put(seen, origin), acc ++ origin_errors(environment, origin, seen, pointer)}
      end)

    count ++ each
  end

  # IN-54
  @doc "True when `origin`, the `Origin` header of a browser request, is on the list exactly; `nil` (no header) is always allowed."
  @spec allowed?([String.t()], String.t() | nil) :: boolean()
  def allowed?(_origins, nil), do: true
  def allowed?(origins, origin) when is_binary(origin), do: origin in origins

  defp origin_errors(environment, origin, seen, pointer) do
    cond do
      not origin?(environment, origin) ->
        [error(pointer, "invalid_format", detail(environment))]

      MapSet.member?(seen, origin) ->
        [error(pointer, "conflict", "the origin is already on the list")]

      true ->
        []
    end
  end

  defp origin?(environment, origin) when is_binary(origin) and byte_size(origin) <= @bytes do
    port?(Regex.run(@https, origin), 443) or
      (environment == :test and port?(Regex.run(@localhost, origin), 80))
  end

  defp origin?(_environment, _origin), do: false

  defp port?(nil, _default), do: false
  defp port?([_origin], _default), do: true
  defp port?([_origin, ""], _default), do: true

  defp port?([_origin, port], default) do
    number = String.to_integer(port)
    number <= 65_535 and number != default
  end

  defp detail(:test),
    do: "an origin is https://host[:port] or http://localhost[:port], without a path"

  defp detail(_environment), do: "an origin is https://host[:port], without a path"

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
