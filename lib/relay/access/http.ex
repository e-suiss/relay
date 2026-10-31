defmodule Relay.Access.Http do
  @moduledoc """
  The HTTP client of the Access link: one JSON `GET` through Req, never inside a database transaction (`Relay.NetworkGuard`, INV-55), with no retry and no redirect; the link's own schedule is the only retry. A body larger than 64 kB, a status other than 200 and a body that is not a JSON object are failures. `config :relay, Relay.Access, http: [...]` adds Req options, such as a test plug.
  """

  @max_bytes 60_000

  # E-78
  # INV-55
  @doc "Fetches a JSON object and returns it with its raw bytes."
  @spec get_json(String.t(), keyword()) :: {:ok, map(), binary()} | {:error, Relay.Error.t()}
  def get_json(url, opts \\ []) when is_binary(url) do
    :ok = Relay.NetworkGuard.check!(:http)

    request =
      [
        url: url,
        method: :get,
        headers: [{"accept", "application/json"}],
        receive_timeout: 5_000,
        decode_body: false
      ]
      |> Keyword.merge(Keyword.get(Relay.Access.config(), :http, []))
      |> Keyword.merge(opts)
      |> Keyword.merge(retry: false, redirect: false)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> decode(body)
      {:ok, %Req.Response{status: status}} -> unreachable("Access answered #{status}")
      {:error, exception} -> unreachable(Exception.message(exception))
    end
  end

  defp decode(body) when byte_size(body) > @max_bytes, do: unreachable("the document is too big")

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> {:ok, document, body}
      _ -> unreachable("the document is not a JSON object")
    end
  end

  defp unreachable(message),
    do: {:error, Relay.Error.new(:access_unreachable, "Access link: " <> message)}
end
