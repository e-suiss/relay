defmodule Relay.Access.Http do
  @moduledoc """
  The HTTP client of the Access link, through Req, never inside a database transaction (`Relay.NetworkGuard`, INV-55), with no retry and no redirect; the link's own schedule is the only retry. `get_json/2` fetches one public JSON document; `request/1` sends one request of Relay's own calls to Access (`Relay.Access.Client`); `mtls_request/1` one AuthZEN evaluation over mutual TLS (`Relay.Access.Pep`). A body larger than 60,000 bytes, a status other than 200 and a body that is not a JSON object are failures of `get_json/2`. `config :relay, Relay.Access, http: [...]` adds Req options, such as a test plug.
  """

  @max_bytes 60_000

  # E-78
  # INV-55
  @doc "Fetches a JSON object and returns it with its raw bytes."
  @spec get_json(String.t(), keyword()) :: {:ok, map(), binary()} | {:error, Relay.Error.t()}
  def get_json(url, opts \\ []) when is_binary(url) do
    request = [url: url, method: :get, headers: [{"accept", "application/json"}]]

    case request(Keyword.merge(request, opts)) do
      {:ok, %Req.Response{status: 200, body: body}} -> json(body)
      {:ok, %Req.Response{status: status}} -> unreachable("Access answered #{status}")
      {:error, error} -> {:error, error}
    end
  end

  # E-98
  # INV-55
  @doc "Sends one request to Access with the given Req options and returns the response, whose body stays raw bytes; only a transport failure is an error."
  @spec request(keyword()) :: {:ok, Req.Response.t()} | {:error, Relay.Error.t()}
  def request(opts) when is_list(opts),
    do: send_request(Keyword.get(Relay.Access.config(), :http, []), opts)

  # E-102
  # INV-55
  @doc "Sends one request to the Access decision point, whose mutual TLS is given in the Req options (`connect_options`), like `request/1`; the link's `http` options do not apply, so it always reaches the network."
  @spec mtls_request(keyword()) :: {:ok, Req.Response.t()} | {:error, Relay.Error.t()}
  def mtls_request(opts) when is_list(opts), do: send_request([], opts)

  defp send_request(link, opts) do
    :ok = Relay.NetworkGuard.check!(:http)

    request =
      [receive_timeout: 5_000, decode_body: false]
      |> Keyword.merge(link)
      |> Keyword.merge(opts)
      |> Keyword.merge(retry: false, redirect: false)

    case Req.request(request) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> unreachable(Exception.message(exception))
    end
  end

  @doc "Decodes a raw body that must be a JSON object of at most 60,000 bytes, and returns it with its raw bytes."
  @spec json(term()) :: {:ok, map(), binary()} | {:error, Relay.Error.t()}
  def json(body) when is_binary(body) and byte_size(body) > @max_bytes,
    do: unreachable("the document is too big")

  def json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> {:ok, document, body}
      _ -> unreachable("the document is not a JSON object")
    end
  end

  def json(_body), do: unreachable("the document is not a JSON object")

  defp unreachable(message),
    do: {:error, Relay.Error.new(:access_unreachable, "Access link: " <> message)}
end
