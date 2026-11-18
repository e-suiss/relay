defmodule Relay.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store client with object lock. Requests are signed with AWS Signature Version 4 and use path-style addressing, so the same client serves AWS S3, MinIO and other compatible stores. Every object is written once and carries its own lock (`x-amz-object-lock-mode`, `x-amz-object-lock-retain-until-date`) in the mode of the bucket's default rule, so it stays locked even if the bucket default is later removed; a bucket without object lock or without a default retention rule is refused.

  A file up to 16 MiB is written with one `PUT` carrying `If-None-Match: *` and a SHA-256 checksum; a larger one with a multipart upload whose parts carry `Content-MD5`, aborted when any part fails. Reads stream the object into a local file.

  Options: `:endpoint` (`https://…`, or `http://…` for a local store), `:bucket`, `:region`, `:access_key_id`, `:secret_access_key` (a `{module, function, args}` callback returning a `Relay.Redacted` value, a zero-arity function, or, outside production, a string or a `Relay.Redacted` value) and `:prefix` (may be empty, otherwise ends with `/`).
  """

  @keys [:endpoint, :bucket, :region, :access_key_id, :secret_access_key, :prefix]
  @part_bytes 16 * 1024 * 1024
  @timeout_ms 120_000

  @type rule :: {String.t(), {:days | :years, pos_integer()}}

  # OP-84
  @doc "Option keys the client requires."
  @spec option_keys() :: [atom(), ...]
  def option_keys, do: @keys

  # OP-84
  @doc "Validates the client options; returns an error message for a missing, unknown or malformed option."
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "options must be a keyword list"}

      (unknown = Keyword.keys(opts) -- @keys) != [] ->
        {:error, "unknown options #{inspect(Enum.sort(unknown))}"}

      (missing = Enum.reject(@keys, &Keyword.has_key?(opts, &1))) != [] ->
        {:error, "missing options #{inspect(missing)}"}

      true ->
        Enum.find_value(checks(opts), :ok, fn
          {true, _message} -> nil
          {false, message} -> {:error, message}
        end)
    end
  end

  defp checks(opts) do
    [
      {endpoint?(opts[:endpoint]), "endpoint must be an http:// or https:// URL without a path"},
      {bucket?(opts[:bucket]), "bucket must be an S3 bucket name"},
      {text?(opts[:region]) and text?(opts[:access_key_id]),
       "region and access_key_id must be non-empty strings"},
      {secret?(opts[:secret_access_key]),
       "secret_access_key must be a callback or a non-empty string"},
      {prefix?(opts[:prefix]), "prefix must be empty or end with /"}
    ]
  end

  # OP-70
  # OP-84
  @doc "Reads the bucket's default object lock rule; an error when the bucket has no object lock or no default retention rule."
  @spec lock_rule(keyword()) :: {:ok, rule()} | {:error, Relay.Error.t()}
  def lock_rule(opts) do
    case request(opts, :get, "", [], nil, [{"object-lock", ""}]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case lock_rule_of(body) do
          {:ok, rule} -> {:ok, rule}
          :error -> error(:target_unlocked, "bucket has no default object lock")
        end

      {:ok, %{status: status}} when status in [403, 404] ->
        error(:target_unlocked, "bucket has no object lock configuration")

      {:ok, %{status: status}} ->
        error(:publication_unreadable, "object store refused", %{status: status})

      {:error, _} = error ->
        error
    end
  end

  # OP-71 (6)
  @doc "The default retention rule of an object lock configuration document: `{:ok, {mode, {unit, count}}}`, or `:error` without object lock or a default rule."
  @spec lock_rule_of(String.t()) :: {:ok, rule()} | :error
  def lock_rule_of(body) when is_binary(body) do
    with true <- Regex.match?(~r/<ObjectLockEnabled>\s*Enabled\s*<\/ObjectLockEnabled>/, body),
         [_, mode] <- Regex.run(~r/<Mode>\s*(GOVERNANCE|COMPLIANCE)\s*<\/Mode>/, body),
         [_, unit, count] <- Regex.run(~r/<(Days|Years)>\s*([1-9][0-9]{0,5})\s*<\/\1>/, body) do
      {:ok, {mode, {unit(unit), String.to_integer(count)}}}
    else
      _ -> :error
    end
  end

  defp unit("Days"), do: :days
  defp unit("Years"), do: :years

  # OP-71 (6)
  # OP-72 (3)
  @doc "Object lock headers of a write at `now`: the mode of the bucket's default rule `{mode, {unit, count}}` and a retain-until date at the later of the rule's period and `days` days after `now`."
  @spec lock_headers(rule(), DateTime.t(), non_neg_integer()) :: [{String.t(), String.t()}]
  def lock_headers({mode, period}, %DateTime{} = now, days \\ 0)
      when mode in ["GOVERNANCE", "COMPLIANCE"] and is_integer(days) and days >= 0 do
    [
      {"x-amz-object-lock-mode", mode},
      {"x-amz-object-lock-retain-until-date",
       DateTime.to_iso8601(retain_until(period, now, days))}
    ]
  end

  # OP-84
  @doc "The retain-until date of a write at `now` under a bucket default period: the later of that period and `days` days after `now`, in whole seconds."
  @spec retain_until({:days | :years, pos_integer()}, DateTime.t(), non_neg_integer()) ::
          DateTime.t()
  def retain_until(period, %DateTime{} = now, days) do
    now = %{now | microsecond: {0, 0}}
    Enum.max([DateTime.shift(now, shift(period)), DateTime.shift(now, day: days)], DateTime)
  end

  defp shift({:days, count}), do: [day: count]
  defp shift({:years, count}), do: [year: count]

  # OP-84
  @doc "Writes `body` once under `key` (below the prefix), locked until `until` in the bucket rule's mode; an existing object with the same content counts as written."
  @spec put_once(keyword(), String.t(), iodata(), DateTime.t(), String.t()) ::
          :ok | {:error, Relay.Error.t()}
  def put_once(opts, key, body, %DateTime{} = until, content_type) do
    body = IO.iodata_to_binary(body)

    with {:ok, {mode, _period}} <- lock_rule(opts) do
      case put(opts, key, body, lock(mode, until) ++ [{"content-type", content_type}]) do
        :exists -> same_object(opts, key, body)
        result -> result
      end
    end
  end

  # OP-84
  @doc "Writes the local file at `path` once under `key` (below the prefix), locked until `until` in the bucket rule's mode; a file above the part size goes up as a multipart upload."
  @spec put_file(keyword(), String.t(), Path.t(), DateTime.t()) :: :ok | {:error, Relay.Error.t()}
  def put_file(opts, key, path, %DateTime{} = until) do
    with {:ok, {mode, _period}} <- lock_rule(opts),
         {:ok, %File.Stat{size: size}} <- stat(path) do
      headers = lock(mode, until) ++ [{"content-type", "application/octet-stream"}]

      if size <= @part_bytes,
        do: put_new(opts, key, read!(path), headers),
        else: multipart(opts, key, path, headers)
    end
  end

  defp put_new(opts, key, body, headers) do
    case put(opts, key, body, headers) do
      :exists -> error(:publication_conflict, "object exists")
      result -> result
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> error(:archive_io, "local file unreadable", %{reason: reason})
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read!(path), do: File.read!(path)

  defp lock(mode, until),
    do: [
      {"x-amz-object-lock-mode", mode},
      {"x-amz-object-lock-retain-until-date", DateTime.to_iso8601(%{until | microsecond: {0, 0}})}
    ]

  defp put(opts, key, body, headers) do
    headers =
      [
        {"if-none-match", "*"},
        {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, body))},
        {"x-amz-sdk-checksum-algorithm", "SHA256"}
      ] ++ headers

    case request(opts, :put, key, headers, body, []) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [409, 412] -> :exists
      {:ok, %{status: status}} -> refused(status)
      {:error, _} = error -> error
    end
  end

  defp same_object(opts, key, body) do
    case get(opts, key) do
      {:ok, ^body} -> :ok
      {:ok, _other} -> error(:publication_conflict, "a different object exists")
      {:error, _} = error -> error
    end
  end

  defp multipart(opts, key, path, headers) do
    with {:ok, upload} <- create_upload(opts, key, headers) do
      case upload_parts(opts, key, upload, path) do
        {:ok, parts} ->
          complete_upload(opts, key, upload, parts)

        {:error, _} = error ->
          _ = request(opts, :delete, key, [], nil, [{"uploadId", upload}])
          error
      end
    end
  end

  defp create_upload(opts, key, headers) do
    case request(opts, :post, key, headers, "", [{"uploads", ""}]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body) do
          [_, upload] -> {:ok, upload}
          nil -> error(:publication_refused, "object store sent no upload id")
        end

      {:ok, %{status: status}} ->
        error(:publication_refused, "object store refused", %{status: status})

      {:error, _} = error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp upload_parts(opts, key, upload, path) do
    path
    |> File.stream!(@part_bytes)
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {chunk, number}, {:ok, parts} ->
      case upload_part(opts, key, upload, number, chunk) do
        {:ok, etag} -> {:cont, {:ok, [{number, etag} | parts]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, _} = error -> error
    end
  end

  defp upload_part(opts, key, upload, number, chunk) do
    headers = [{"content-md5", Base.encode64(:crypto.hash(:md5, chunk))}]
    query = [{"partNumber", Integer.to_string(number)}, {"uploadId", upload}]

    case request(opts, :put, key, headers, chunk, query) do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_header(response, "etag") do
          [etag | _] -> {:ok, etag}
          [] -> error(:publication_refused, "object store sent no part tag")
        end

      {:ok, %{status: status}} ->
        error(:publication_refused, "object store refused", %{status: status})

      {:error, _} = error ->
        error
    end
  end

  defp complete_upload(opts, key, upload, parts) do
    body =
      IO.iodata_to_binary([
        "<CompleteMultipartUpload>",
        Enum.map(parts, fn {number, etag} ->
          "<Part><PartNumber>#{number}</PartNumber><ETag>#{etag}</ETag></Part>"
        end),
        "</CompleteMultipartUpload>"
      ])

    headers = [{"content-type", "application/xml"}]

    case request(opts, :post, key, headers, body, [{"uploadId", upload}]) do
      {:ok, %{status: 200, body: response}} when is_binary(response) ->
        if response =~ "<Error>",
          do: error(:publication_refused, "object store refused the upload"),
          else: :ok

      {:ok, %{status: status}} ->
        error(:publication_refused, "object store refused", %{status: status})

      {:error, _} = error ->
        error
    end
  end

  # OP-84
  @doc "Reads the object under `key` (below the prefix) into memory; for small objects."
  @spec get(keyword(), String.t()) :: {:ok, binary()} | {:error, Relay.Error.t()}
  def get(opts, key) do
    case request(opts, :get, key, [], nil, []) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> error(:publication_missing, "object not found")
      {:ok, %{status: status}} -> unreadable(status)
      {:error, _} = error -> error
    end
  end

  # OP-84
  @doc "Streams the object under `key` (below the prefix) into a new local file at `path`."
  @spec get_file(keyword(), String.t(), Path.t()) :: :ok | {:error, Relay.Error.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def get_file(opts, key, path) do
    case request(opts, :get, key, [], nil, [], into: File.stream!(path)) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        error(:publication_missing, "object not found")

      {:ok, %{status: status}} ->
        error(:publication_unreadable, "object store refused", %{status: status})

      {:error, _} = error ->
        error
    end
  end

  defp request(opts, method, key, headers, body, query, extra \\ []) do
    url =
      opts
      |> Keyword.fetch!(:endpoint)
      |> URI.parse()
      |> URI.append_path(path(opts, key))
      |> then(&if(query == [], do: &1, else: %{&1 | query: URI.encode_query(query)}))

    req =
      Req.new(
        [
          method: method,
          url: url,
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
        ] ++ extra
      )

    :ok = Relay.NetworkGuard.check!(:http)
    :ok = Relay.Hygiene.sensitive!()

    case Req.request(req) do
      {:ok, response} ->
        {:ok, response}

      {:error, exception} ->
        error(:publication_unreachable, "object store unreachable", %{
          reason: inspect(exception.__struct__)
        })
    end
  end

  defp path(opts, key),
    do: "/" <> Keyword.fetch!(opts, :bucket) <> "/" <> encode(object(opts, key))

  defp object(_opts, ""), do: ""
  defp object(opts, key), do: Keyword.fetch!(opts, :prefix) <> key

  defp encode(key), do: URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))

  defp error(code, message, details \\ %{}),
    do: {:error, Relay.Error.new(code, message, details)}

  defp refused(status), do: error(:publication_refused, "object store refused", %{status: status})

  defp unreadable(status),
    do: error(:publication_unreadable, "object store refused", %{status: status})

  defp endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, path: path, query: nil, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path in [nil, "", "/"]

      _ ->
        false
    end
  end

  defp endpoint?(_endpoint), do: false

  defp bucket?(bucket),
    do: is_binary(bucket) and Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, bucket)

  defp text?(value), do: is_binary(value) and value != ""

  defp secret?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp secret?(fun) when is_function(fun, 0), do: true

  defp secret?(value) do
    if Relay.Redacted.redacted?(value),
      do: text?(Relay.Redacted.expose(value)),
      else: text?(value)
  end

  # TN-67 (3)
  defp secret({module, function, args}), do: secret(apply(module, function, args))
  defp secret(fun) when is_function(fun, 0), do: secret(fun.())
  defp secret(value), do: value |> Relay.Redacted.wrap() |> Relay.Redacted.expose()

  defp prefix?(""), do: true
  defp prefix?(prefix) when is_binary(prefix), do: String.ends_with?(prefix, "/")
  defp prefix?(_prefix), do: false
end
