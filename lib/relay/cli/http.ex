defmodule Relay.CLI.HTTP do
  @moduledoc """
  The HTTP layer of the command line tool, on Req. Redirects and Req's own retries are off (`Relay.CLI.Client` decides on retries); JSON bodies are decoded whatever their JSON media type. The `:http` options of the run are merged into every request, which is how tests answer without a network.
  """

  alias Relay.CLI.Context

  @timeout_ms 30_000
  @user_agent "relay-cli/" <> Mix.Project.config()[:version]

  @type response :: %{
          status: integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: term()
        }

  @doc "Sends one request; a transport failure returns its readable reason."
  @spec request(Context.t(), keyword()) :: {:ok, response()} | {:error, String.t()}
  def request(%Context{} = ctx, opts) when is_list(opts) do
    base = [
      retry: false,
      redirect: false,
      decode_body: false,
      user_agent: @user_agent,
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]

    request = base |> Keyword.merge(opts) |> Req.new() |> Req.merge(ctx.http)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: decode(headers, body)}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc "The first value of a response header, or nil."
  @spec header(response(), String.t()) :: String.t() | nil
  def header(%{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      _other -> nil
    end
  end

  defp decode(headers, body) when is_binary(body) and body != "" do
    with [type | _rest] <- Map.get(headers, "content-type"),
         true <- String.contains?(type, "json"),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _other -> body
    end
  end

  defp decode(_headers, body), do: body
end
