defmodule Relay.TenantLifecycle.ExportStore.S3 do
  @moduledoc """
  Export store on an S3-compatible object store. Objects are written with a SHA-256 checksum and requests are signed with AWS Signature Version 4 and use path-style addressing, as the audit publisher does; a download link is a presigned `GET` URL that expires.

  Options: `:endpoint` (`https://…`, or `http://…` for a local store), `:bucket`, `:region`, `:access_key_id`, `:secret_access_key` (a runtime callback `{module, function, args}` returning a `Relay.Redacted` value, a zero-arity function, or outside production a string), `:prefix` (empty or ending with `/`) and, for tests, `:req_options`.
  """

  @behaviour Relay.TenantLifecycle.ExportStore

  @timeout_ms 30_000

  # OP-86
  @impl Relay.TenantLifecycle.ExportStore
  @doc "Writes one object."
  @spec put(String.t(), iodata(), String.t(), keyword()) :: :ok | {:error, Relay.Error.t()}
  def put(key, body, content_type, opts) do
    body = IO.iodata_to_binary(body)

    headers = [
      {"content-type", content_type},
      {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, body))},
      {"x-amz-sdk-checksum-algorithm", "SHA256"}
    ]

    req =
      Req.new(
        [
          method: :put,
          url: object_url(opts, key),
          headers: headers,
          body: body,
          retry: false,
          redirect: false,
          decode_body: false,
          compressed: false,
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms],
          aws_sigv4: [
            access_key_id: Keyword.fetch!(opts, :access_key_id),
            secret_access_key: secret(Keyword.fetch!(opts, :secret_access_key)),
            service: :s3,
            region: Keyword.fetch!(opts, :region),
            datetime: Relay.Clock.utc_now()
          ]
        ] ++ Keyword.get(opts, :req_options, [])
      )

    :ok = Relay.NetworkGuard.check!(:http)
    :ok = Relay.Hygiene.sensitive!()

    case Req.request(req) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        details = %{status: status}
        {:error, Relay.Error.new(:export_store_refused, "object store refused", details)}

      {:error, exception} ->
        {:error,
         Relay.Error.new(:export_store_unreachable, "object store unreachable", %{
           reason: inspect(exception.__struct__)
         })}
    end
  end

  # OP-86
  @impl Relay.TenantLifecycle.ExportStore
  @doc "A presigned download URL of an object that expires after `ttl_s` seconds, at most seven days."
  @spec url(String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def url(key, ttl_s, opts) when is_integer(ttl_s) and ttl_s > 0 and ttl_s <= 604_800 do
    :ok = Relay.Hygiene.sensitive!()

    signed =
      Req.Utils.aws_sigv4_url(
        access_key_id: Keyword.fetch!(opts, :access_key_id),
        secret_access_key: secret(Keyword.fetch!(opts, :secret_access_key)),
        region: Keyword.fetch!(opts, :region),
        service: :s3,
        datetime: Relay.Clock.utc_now(),
        method: :get,
        url: object_url(opts, key),
        expires: ttl_s
      )

    {:ok, URI.to_string(signed)}
  end

  defp object_url(opts, key) do
    opts
    |> Keyword.fetch!(:endpoint)
    |> URI.parse()
    |> URI.append_path(
      "/" <> Keyword.fetch!(opts, :bucket) <> "/" <> encode(Keyword.get(opts, :prefix, "") <> key)
    )
    |> URI.to_string()
  end

  defp encode(key), do: URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))

  # TN-67 (3)
  defp secret({module, function, args}), do: secret(apply(module, function, args))
  defp secret(fun) when is_function(fun, 0), do: secret(fun.())
  defp secret(value), do: value |> Relay.Redacted.wrap() |> Relay.Redacted.expose()
end
