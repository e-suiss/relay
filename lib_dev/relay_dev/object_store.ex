defmodule RelayDev.ObjectStore do
  @moduledoc """
  Local object store setup for the audit checkpoint target of `deploy/compose.yaml`: creates a bucket with object lock enabled and a default retention rule on the local MinIO, idempotently. Development and test only; a production bucket is created and locked by the installation operator.
  """

  @local [
    endpoint: "http://localhost:9000",
    bucket: "relay-audit",
    region: "us-east-1",
    access_key_id: "relay",
    secret_access_key: "relay-dev-secret",
    prefix: ""
  ]
  @retention """
  <ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days></DefaultRetention></Rule></ObjectLockConfiguration>
  """

  # OP-70
  @doc "Options of the local MinIO target; `bucket:` and `prefix:` may be overridden."
  @spec local(keyword()) :: keyword()
  def local(overrides \\ []), do: Keyword.merge(@local, overrides)

  @doc "Creates the bucket of `opts` with object lock and a one-day governance retention unless it exists, waiting up to `wait_ms` for the store."
  @spec setup(keyword(), non_neg_integer()) :: :ok | {:error, term()}
  def setup(opts \\ local(), wait_ms \\ 30_000) do
    with :ok <- wait(opts, wait_ms),
         :ok <- create_bucket(opts, [{"x-amz-bucket-object-lock-enabled", "true"}]) do
      lock(opts)
    end
  end

  @doc "Creates the bucket of `opts` without object lock; for tests of the target check."
  @spec setup_unlocked(keyword(), non_neg_integer()) :: :ok | {:error, term()}
  def setup_unlocked(opts, wait_ms \\ 30_000) do
    with :ok <- wait(opts, wait_ms), do: create_bucket(opts, [])
  end

  defp wait(opts, wait_ms) do
    case request(opts, :head, "", [], nil, []) do
      {:ok, %{status: status}} when status in [200, 404] ->
        :ok

      _ when wait_ms > 0 ->
        Process.sleep(500)
        wait(opts, wait_ms - 500)

      other ->
        {:error, other}
    end
  end

  defp create_bucket(opts, headers) do
    case request(opts, :put, "", headers, "", []) do
      {:ok, %{status: status}} when status in [200, 409] -> :ok
      other -> {:error, other}
    end
  end

  defp lock(opts) do
    body = String.trim(@retention)
    md5 = Base.encode64(:crypto.hash(:md5, body))

    case request(opts, :put, "", [{"content-md5", md5}], body, [{"object-lock", ""}]) do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, other}
    end
  end

  @doc "Writes an object without any precondition, as an attacker holding the store credentials would; for tamper tests."
  @spec overwrite(keyword(), String.t(), binary()) :: {:ok, Req.Response.t()} | {:error, term()}
  def overwrite(opts, key, body) do
    checksum = Base.encode64(:crypto.hash(:sha256, body))
    request(opts, :put, key, [{"x-amz-checksum-sha256", checksum}], body, [])
  end

  @doc "Tries to delete an object, or one version of it; for tamper tests."
  @spec delete(keyword(), String.t(), String.t() | nil) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def delete(opts, key, version_id \\ nil) do
    query = if version_id, do: [{"versionId", version_id}], else: []
    request(opts, :delete, key, [], nil, query)
  end

  @doc "Returns the object lock retention of an object: `{:ok, {mode, retain_until}}`."
  @spec retention(keyword(), String.t()) :: {:ok, {String.t(), DateTime.t()}} | {:error, term()}
  def retention(opts, key) do
    with {:ok, %{status: 200, body: body}} <-
           request(opts, :get, key, [], nil, [{"retention", ""}]),
         [_, mode] <- Regex.run(~r/<Mode>([A-Z]+)<\/Mode>/, body),
         [_, until] <- Regex.run(~r/<RetainUntilDate>([^<]+)<\/RetainUntilDate>/, body),
         {:ok, until, 0} <- DateTime.from_iso8601(until) do
      {:ok, {mode, until}}
    else
      other -> {:error, other}
    end
  end

  @doc "Lists the object keys under `prefix`."
  @spec keys(keyword(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def keys(opts, prefix) do
    case request(opts, :get, "", [], nil, [{"list-type", "2"}, {"prefix", prefix}]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, for([_, key] <- Regex.scan(~r/<Key>([^<]+)<\/Key>/, body), do: key)}

      other ->
        {:error, other}
    end
  end

  @doc "Returns the current version id of an object."
  @spec version(keyword(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def version(opts, key) do
    case request(opts, :head, key, [], nil, []) do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_header(response, "x-amz-version-id") do
          [version | _] -> {:ok, version}
          [] -> {:error, :unversioned}
        end

      other ->
        {:error, other}
    end
  end

  defp request(opts, method, key, headers, body, query) do
    url =
      opts[:endpoint]
      |> URI.parse()
      |> URI.append_path("/" <> opts[:bucket] <> "/" <> key)
      |> then(&if(query == [], do: &1, else: %{&1 | query: URI.encode_query(query)}))

    Req.request(
      method: method,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      decode_body: false,
      compressed: false,
      aws_sigv4: [
        access_key_id: opts[:access_key_id],
        secret_access_key: opts[:secret_access_key],
        service: :s3,
        region: opts[:region]
      ]
    )
  end
end
