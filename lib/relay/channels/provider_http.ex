defmodule Relay.Channels.ProviderHttp do
  @moduledoc """
  The shared HTTP call of the thin provider adapters (CH-3, T-40). It sends one request through `Relay.Channels.http_request/1` (no retry, no redirect, TLS always verified), bounded by the attempt's timeout (CH-9), and tells the two transport failures apart: a request that never left (no connection) is `{:not_sent, reason}` and a request whose answer never came is `{:uncertain, reason}` (T-28). The answer itself is returned as it came; the adapter only reads it.

  The installation may add Req options under `config :relay, Relay.Channels, http: [...]`, which the tests use for a `Req.Test` stub.
  """

  alias Relay.Channels.Request

  @connect ~w(econnrefused nxdomain ehostunreach enetunreach eaddrnotavail)a
  @connect_ms 5_000

  @type answer :: {:ok, Req.Response.t()} | {:not_sent, String.t()} | {:uncertain, String.t()}

  # CH-9
  # T-28
  # T-43
  @doc "Sends one provider request within `timeout_ms`."
  @spec call(keyword(), pos_integer()) :: answer()
  def call(opts, timeout_ms) when is_list(opts) and is_integer(timeout_ms) and timeout_ms > 0 do
    extra = :relay |> Application.get_env(Relay.Channels, []) |> Keyword.get(:http, [])

    opts =
      opts
      |> Keyword.merge(receive_timeout: timeout_ms, pool_timeout: min(timeout_ms, @connect_ms))
      |> Keyword.put(:connect_options, timeout: min(timeout_ms, @connect_ms))
      |> Keyword.merge(extra)

    case Relay.Channels.http_request(opts) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} when reason in @connect ->
        {:not_sent, name(reason)}

      {:error, %Req.TransportError{reason: reason}} ->
        {:uncertain, name(reason)}

      {:error, _exception} ->
        {:uncertain, "error"}
    end
  end

  defp name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp name(_reason), do: "error"

  # CH-9
  @doc "The provider's `Retry-After` of a response in milliseconds, or `nil`."
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> Relay.Channels.retry_after_ms(value, Relay.Clock.utc_now())
      [] -> nil
    end
  end

  @doc "The E.164 number of a target without its leading `+`."
  @spec digits(Request.t()) :: String.t()
  def digits(request) do
    case Relay.Redacted.expose(request.target.value) do
      "+" <> digits -> digits
      digits -> digits
    end
  end

  @doc "The value of a setting of the request's provider account, or `nil`."
  @spec setting(Relay.Channels.Request.t(), String.t()) :: term()
  def setting(%{account: %{"settings" => %{} = settings}}, key), do: Map.get(settings, key)
  def setting(_request, _key), do: nil

  @doc "The sender value of the request's sender identity, or `nil`."
  @spec sender(Request.t()) :: String.t() | nil
  def sender(%{sender: %{"value" => value}}) when is_binary(value), do: value
  def sender(_request), do: nil

  @doc "The text of the request's rendered content."
  @spec text(Request.t()) :: String.t()
  def text(%{content: %{"body" => body}}) when is_binary(body), do: body
  def text(%{content: body}) when is_binary(body), do: body
  def text(_request), do: ""

  @doc "The exposed credential of the request, or an empty string."
  @spec secret(Request.t()) :: String.t()
  def secret(%{credentials: nil}), do: ""
  def secret(%{credentials: credentials}), do: Relay.Redacted.expose(credentials)
end
