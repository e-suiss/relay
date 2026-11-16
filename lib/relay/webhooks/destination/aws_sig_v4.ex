defmodule Relay.Webhooks.Destination.AwsSigV4 do
  @moduledoc """
  AWS Signature Version 4 for the header-signed requests of the AWS destinations and of S3 compatible object stores (WH-17). The module is pure: the time is an argument and nothing is sent.

  `sign/4` returns the headers of the request with `x-amz-date`, the session token of temporary credentials and `authorization` added. Every header the request carries is signed, together with `host`, which is taken from the URL as it will be sent: the host name, and the port when it is not 443. For S3 the path is signed as it is written and the payload digest travels in `x-amz-content-sha256`; for every other service each path segment is encoded once more, as the signature version asks.

  The secret access key and the session token are wrapped values. The secret is read only to derive the signing key and appears in nothing this module returns (WH-19).
  """

  alias Relay.Redacted

  @algorithm "AWS4-HMAC-SHA256"
  @plain ~r/\A[\x21-\x7E]+\z/

  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => Redacted.t(),
          optional(:session_token) => Redacted.t() | nil
        }
  @type request :: %{
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata()
        }
  @type scope :: %{region: String.t(), service: String.t()}

  # WH-17
  @doc "Signs a request at `now` for a region and a service and returns its headers with the signature headers added."
  @spec sign(request(), credentials(), scope(), DateTime.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :invalid_url}
  def sign(%{url: url} = request, credentials, scope, %DateTime{} = now) when is_binary(url) do
    case parse(url) do
      {:ok, uri} -> {:ok, signed(request, uri, credentials, scope, now)}
      :error -> {:error, :invalid_url}
    end
  end

  defp parse(url) do
    with true <- Regex.match?(@plain, url),
         {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" <- URI.new(url) do
      {:ok, uri}
    else
      _invalid -> :error
    end
  end

  defp signed(request, uri, credentials, scope, now) do
    digest = hex(:crypto.hash(:sha256, request.body))
    stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    headers = request.headers ++ added(credentials, scope, stamp, digest)
    canonical = canonical_headers([{"host", host(uri)} | headers])
    names = Enum.map_join(canonical, ";", &elem(&1, 0))


    parts = [
      request.method,
      canonical_path(uri.path, scope.service),
      canonical_query(uri.query),
      Enum.map_join(canonical, "", fn {name, value} -> name <> ":" <> value <> "\n" end),
      names,
      digest
    ]

    credential_scope = scope(stamp, scope)
    request_hash = hashed(Enum.join(parts, "\n"))
    to_sign = Enum.join([@algorithm, stamp, credential_scope, request_hash], "\n")
    signature = hex(hmac(signing_key(credentials, stamp, scope), to_sign))

    authorization =
      IO.iodata_to_binary([
        @algorithm,
        " Credential=",
        credentials.access_key_id,
        "/",
        credential_scope,
        ", SignedHeaders=",
        names,
        ", Signature=",
        signature
      ])

    headers ++ [{"authorization", authorization}]
  end

  defp added(credentials, scope, stamp, digest) do
    [{"x-amz-date", stamp}] ++ payload(scope.service, digest) ++ token(credentials)
  end

  defp payload("s3", digest), do: [{"x-amz-content-sha256", digest}]
  defp payload(_service, _digest), do: []

  defp token(credentials) do
    case Map.get(credentials, :session_token) do
      nil -> []
      token -> [{"x-amz-security-token", Redacted.expose(token)}]
    end
  end

  defp host(%URI{host: host, port: port}) when port in [nil, 443], do: host
  defp host(%URI{host: host, port: port}), do: host <> ":" <> Integer.to_string(port)

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name, :ascii), squeeze(value)} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, values} -> {name, Enum.join(values, ",")} end)
    |> Enum.sort()
  end

  defp squeeze(value), do: value |> String.split() |> Enum.join(" ")

  defp canonical_path(path, _service) when path in [nil, ""], do: "/"
  defp canonical_path(path, "s3"), do: path

  defp canonical_path(path, _service),
    do: path |> String.split("/") |> Enum.map_join("/", &encode/1)

  defp canonical_query(nil), do: ""

  defp canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(&parameter/1)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> name <> "=" <> value end)
  end

  defp parameter(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, value] -> {encode(URI.decode(name)), encode(URI.decode(value))}
      [name] -> {encode(URI.decode(name)), ""}
    end
  end

  defp encode(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp scope(stamp, %{region: region, service: service}),
    do: Enum.join([binary_part(stamp, 0, 8), region, service, "aws4_request"], "/")

  defp signing_key(credentials, stamp, %{region: region, service: service}) do
    secret = Redacted.expose(credentials.secret_access_key)

    date_key = hmac("AWS4" <> secret, binary_part(stamp, 0, 8))
    date_key |> hmac(region) |> hmac(service) |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hashed(text), do: hex(:crypto.hash(:sha256, text))
  defp hex(binary), do: Base.encode16(binary, case: :lower)
end
