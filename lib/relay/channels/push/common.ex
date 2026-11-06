defmodule Relay.Channels.Push.Common do
  @moduledoc """
  What the push adapters share: reading the provider account settings, the rendered fields and the target device, the adapter's own raw codes, and the HTTP call of the adapters that run on `Relay.Channels.http_request/1`.

  An adapter reports a request it cannot build with one of its own raw codes, which its declaration maps like any provider code (CH-7): `relay:not_configured` (`sender_config`: the account lacks a setting the adapter needs), `relay:invalid_request` and `relay:payload_too_large` (`permanent_content`), `relay:content_forbidden` (`permanent_content`: a code, secret or authentication link in the payload, INV-60) and `relay:silent_not_supported` (`permanent_content`: a `system` message on Web Push, CH-26).
  """

  alias Relay.Channels.Request

  @codes %{
    push_payload_too_large: "relay:payload_too_large",
    push_content_forbidden: "relay:content_forbidden",
    web_push_silent: "relay:silent_not_supported"
  }

  @doc "The adapter's own raw codes."
  @spec codes() :: [String.t(), ...]
  def codes,
    do: ["relay:not_configured", "relay:invalid_request" | Map.values(@codes)] |> Enum.sort()

  @doc "The rejection of a request the adapter cannot build, from the builder's error."
  @spec rejection(Relay.Error.t() | atom()) :: {:rejected, map()}
  def rejection(:not_configured), do: raw("relay:not_configured")
  def rejection(%Relay.Error{code: code}), do: raw(Map.get(@codes, code, "relay:invalid_request"))

  defp raw(code), do: {:rejected, %{code: code, status: nil, detail: %{}}}

  @doc "Reads the named string settings of the request's provider account; any missing one is `:not_configured`."
  @spec settings(Request.t(), [String.t()]) :: {:ok, map()} | {:error, :not_configured}
  def settings(%Request{account: account}, names) do
    settings = (account && account["settings"]) || %{}

    if Enum.all?(names, &(is_binary(settings[&1]) and settings[&1] != "")),
      do: {:ok, settings},
      else: {:error, :not_configured}
  end

  @doc "The target device's metadata (`platform`, `app`, `apns_environment`, `keys`), empty for another target."
  @spec device(Request.t()) :: map()
  def device(%Request{target: target}), do: Map.get(target, :device) || %{}

  @doc "The rendered push fields: `title`, `subtitle` and `body`; the body of a `sensitive` template is its neutral lock screen text."
  @spec fields(Request.t()) :: %{String.t() => String.t()}
  def fields(%Request{content: %{} = content}) do
    content
    |> Map.take(["title", "subtitle", "body"])
    |> Map.reject(fn {_key, value} -> not is_binary(value) or value == "" end)
  end

  def fields(%Request{}), do: %{}

  @doc "The raw provider overrides of a block (`apns`, `fcm`, `hms`), or `nil` (API-23)."
  @spec override(Request.t(), String.t(), String.t()) :: map() | nil
  def override(%Request{overrides: overrides}, block, field) do
    case overrides do
      %{^block => %{^field => %{} = value}} -> value
      _none -> nil
    end
  end

  @doc "The opaque content identifier of a content-free push: the delivery identifier."
  @spec content_id(Request.t()) :: String.t()
  def content_id(%Request{push: %{content_id: id}}) when is_binary(id), do: id
  def content_id(%Request{delivery_id: id}), do: Relay.Id.to_string(id)

  # T-26
  # T-43
  @doc "Sends one HTTP request through `Relay.Channels.http_request/1`, with the adapter's configured `:http` options (tests answer through a plug), and returns the status, the lower-case headers and the body; a transport failure is `{:error, :not_sent | :uncertain}`."
  @spec http(module(), map(), pos_integer()) ::
          {:ok, map()} | {:error, :not_sent | :uncertain}
  def http(adapter, %{method: method, url: url, headers: headers, body: body}, timeout_ms) do
    opts =
      [
        method: method,
        url: url,
        headers: headers,
        body: body,
        decode_body: false,
        receive_timeout: timeout_ms,
        connect_options: [timeout: min(timeout_ms, 5_000)]
      ]
      |> Keyword.merge(config(adapter, :http, []))

    case Relay.Channels.http_request(opts) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: flat(headers), body: body}}

      {:error, %Req.TransportError{reason: reason}} when reason in [:econnrefused, :nxdomain] ->
        {:error, :not_sent}

      {:error, _error} ->
        {:error, :uncertain}
    end
  end

  defp flat(headers),
    do: Enum.flat_map(headers, fn {name, values} -> Enum.map(values, &{name, &1}) end)

  @doc "An adapter's installation configuration value under `config :relay, <adapter>`."
  @spec config(module(), atom(), term()) :: term()
  def config(adapter, key, default),
    do: :relay |> Application.get_env(adapter, []) |> Keyword.get(key, default)
end
