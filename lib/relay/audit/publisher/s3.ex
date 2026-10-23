defmodule Relay.Audit.Checkpointer.Publisher.S3 do
  @moduledoc """
  Publication target on an S3-compatible object store with object lock (WORM). Each checkpoint is written once, as `<prefix><origin>/<tree size>/<checkpoint id>` with its signed note as the body, `If-None-Match: *` and a SHA-256 checksum; requests are signed with AWS Signature Version 4 and use path-style addressing, so the same adapter serves AWS S3, MinIO and other compatible stores.

  Retention comes from the bucket's default object lock rule and from the object itself: every write reads the bucket's rule and sets the same mode and retention period on the object (`x-amz-object-lock-mode`, `x-amz-object-lock-retain-until-date`), so an object stays locked even if the bucket default is later removed. `check/1` refuses a bucket without object lock or without a default retention rule, and `probe/1`, run when a production node starts, writes a probe object under `<prefix>_probe/` and reads it back.

  Options, all required: `:endpoint` (`https://…`, or `http://…` for a local store), `:bucket`, `:region`, `:access_key_id`, `:secret_access_key` and `:prefix` (may be empty, otherwise ends with `/`). The secret is a runtime callback `{module, function, args}` returning a `Relay.Redacted` value (`Relay.Config.SecretFiles` in production), a zero-arity function, or, outside production, a string or a `Relay.Redacted` value; the process making a request is marked sensitive.
  """

  @behaviour Relay.Audit.Checkpointer.Publisher

  @keys [:endpoint, :bucket, :region, :access_key_id, :secret_access_key, :prefix]
  @timeout_ms 10_000
  @max_body 65_536

  # OP-70
  @doc "Option keys the adapter requires."
  @spec option_keys() :: [atom(), ...]
  def option_keys, do: @keys

  # OP-63
  # OP-70
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "The adapter is a target independent of Relay's own operation."
  @spec independent?() :: true
  def independent?, do: true

  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Validates the adapter options; returns an error message for a missing, unknown or malformed option."
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
        Enum.find_value(values(opts), :ok, &invalid/1)
    end
  end

  defp invalid({true, _message}), do: nil
  defp invalid({false, message}), do: {:error, message}

  defp values(opts) do
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

  defp bucket?(bucket),
    do: is_binary(bucket) and Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, bucket)

  # OP-70
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Writes the signed note of a checkpoint once; an existing object with the same content counts as published."
  @spec publish(Relay.Audit.Checkpointer.Publisher.checkpoint(), keyword()) ::
          :ok | {:error, Relay.Error.t()}
  def publish(checkpoint, opts) do
    case put_once(opts, key(checkpoint, opts), checkpoint.signed_note) do
      :exists -> same_object(opts, key(checkpoint, opts), checkpoint.signed_note)
      result -> result
    end
  end

  # OP-71 (6)
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Probes the target when a production node starts: checks the bucket's object lock, writes a locked probe object and reads it back."
  @spec probe(keyword()) :: :ok | {:error, Relay.Error.t()}
  def probe(opts) do
    id = Relay.Id.to_string(Relay.Id.generate())
    key = Keyword.fetch!(opts, :prefix) <> "_probe/" <> id
    body = "relay audit target probe " <> id <> "\n"

    case put_once(opts, key, body) do
      :ok -> same_object(opts, key, body)
      :exists -> {:error, Relay.Error.new(:publication_conflict, "probe object exists")}
      {:error, _} = error -> error
    end
  end

  defp put_once(opts, key, body) do
    with {:ok, lock} <- lock_rule(opts) do
      headers =
        [
          {"content-type", "text/plain; charset=utf-8"},
          {"if-none-match", "*"},
          {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, body))},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ] ++ lock_headers(lock, Relay.Clock.utc_now())

      case request(opts, :put, key, headers, body) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} when status in [409, 412] ->
          :exists

        {:ok, %{status: status}} ->
          {:error,
           Relay.Error.new(:publication_refused, "object store refused", %{status: status})}

        {:error, _} = error ->
          error
      end
    end
  end

  defp same_object(opts, key, body) do
    case get(opts, key) do
      {:ok, ^body} ->
        :ok

      {:ok, _other} ->
        {:error, Relay.Error.new(:publication_conflict, "a different object exists")}

      {:error, _} = error ->
        error
    end
  end

  # OP-71 (6)
  @doc "Object lock headers of a write at `now`: the mode and the retain-until date of the bucket's default rule `{mode, {unit, count}}`."
  @spec lock_headers({String.t(), {:days | :years, pos_integer()}}, DateTime.t()) :: [
          {String.t(), String.t()}
        ]
  def lock_headers({mode, period}, %DateTime{} = now) when mode in ["GOVERNANCE", "COMPLIANCE"] do
    until = %{now | microsecond: {0, 0}} |> DateTime.shift(shift(period)) |> DateTime.to_iso8601()

    [{"x-amz-object-lock-mode", mode}, {"x-amz-object-lock-retain-until-date", until}]
  end

  defp shift({:days, count}), do: [day: count]
  defp shift({:years, count}), do: [year: count]

  # OP-70
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Reads the published signed note of a checkpoint back from the store."
  @spec read(Relay.Audit.Checkpointer.Publisher.checkpoint(), keyword()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def read(checkpoint, opts), do: get(opts, key(checkpoint, opts))

  defp get(opts, key) do
    case request(opts, :get, key, [], nil) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= @max_body ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, Relay.Error.new(:publication_invalid, "published object is too large")}

      {:ok, %{status: 404}} ->
        {:error, Relay.Error.new(:publication_missing, "published object not found")}

      {:ok, %{status: status}} ->
        {:error,
         Relay.Error.new(:publication_unreadable, "object store refused", %{status: status})}

      {:error, _} = error ->
        error
    end
  end

  # OP-70
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Checks that the bucket has object lock enabled with a default retention rule."
  @spec check(keyword()) :: :ok | {:error, Relay.Error.t()}
  def check(opts) do
    with {:ok, _rule} <- lock_rule(opts), do: :ok
  end

  defp lock_rule(opts) do
    case request(opts, :get, "", [], nil, [{"object-lock", ""}]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case lock_rule_of(body) do
          {:ok, rule} ->
            {:ok, rule}

          :error ->
            {:error, Relay.Error.new(:target_unlocked, "bucket has no default object lock")}
        end

      {:ok, %{status: status}} when status in [403, 404] ->
        {:error, Relay.Error.new(:target_unlocked, "bucket has no object lock configuration")}

      {:ok, %{status: status}} ->
        {:error,
         Relay.Error.new(:publication_unreadable, "object store refused", %{status: status})}

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns true if an object lock configuration document enables object lock with a default retention rule."
  @spec locked?(String.t()) :: boolean()
  def locked?(body) when is_binary(body), do: lock_rule_of(body) != :error

  # OP-71 (6)
  @doc "The default retention rule of an object lock configuration document: `{:ok, {mode, {unit, count}}}`, or `:error` without object lock or a default rule."
  @spec lock_rule_of(String.t()) ::
          {:ok, {String.t(), {:days | :years, pos_integer()}}} | :error
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

  @doc "Object key of a checkpoint."
  @spec key(Relay.Audit.Checkpointer.Publisher.checkpoint(), keyword()) :: String.t()
  def key(checkpoint, opts),
    do:
      Keyword.fetch!(opts, :prefix) <>
        checkpoint.origin <>
        "/" <> Integer.to_string(checkpoint.tree_size) <> "/" <> Relay.Id.to_string(checkpoint.id)

  defp request(opts, method, key, headers, body, query \\ []) do
    url =
      opts
      |> Keyword.fetch!(:endpoint)
      |> URI.parse()
      |> URI.append_path("/" <> Keyword.fetch!(opts, :bucket) <> "/" <> encode(key))
      |> then(&if(query == [], do: &1, else: %{&1 | query: URI.encode_query(query)}))

    req =
      Req.new(
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
      )

    :ok = Relay.NetworkGuard.check!(:http)
    :ok = Relay.Hygiene.sensitive!()

    case Req.request(req) do
      {:ok, response} ->
        {:ok, response}

      {:error, exception} ->
        {:error,
         Relay.Error.new(:publication_unreachable, "object store unreachable", %{
           reason: inspect(exception.__struct__)
         })}
    end
  end

  defp encode(key), do: URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))

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
