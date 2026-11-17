defmodule EsuissRelay.Transport.Httpc do
  @moduledoc """
  The default transport, on Erlang's `:httpc`. TLS peers are verified against the operating
  system's trust store (`:public_key.cacerts_get/0`) with host name checking.
  """

  @behaviour EsuissRelay.Transport

  @impl true
  def request(_state, request) do
    {:ok, _started} = Application.ensure_all_started([:inets, :ssl])
    url = String.to_charlist(request.url)
    {content_type, headers} = split_content_type(request.headers)
    headers = Enum.map(headers, fn {name, value} -> {~c"#{name}", ~c"#{value}"} end)

    http_request =
      if request.method in [:post, :put, :patch] or request.body != nil,
        do: {url, headers, ~c"#{content_type || "application/json"}", request.body || ""},
        else: {url, headers}

    http_options = [timeout: request.timeout, connect_timeout: request.timeout, ssl: ssl()]

    case :httpc.request(request.method, http_request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok, %{status: status, headers: normalize(response_headers), body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_content_type(headers) do
    case List.keytake(headers, "content-type", 0) do
      {{_name, value}, rest} -> {value, rest}
      nil -> {nil, headers}
    end
  end

  defp normalize(headers),
    do: Enum.map(headers, fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)

  defp ssl do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
