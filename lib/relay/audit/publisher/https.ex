defmodule Relay.Audit.Checkpointer.Publisher.Https do
  @moduledoc """
  The HTTPS transport of the SIEM and customer publication targets. A body of JSON lines is sent with `POST` and signed with HMAC-SHA256 computed inside the key store under the target's key (`:hmac_label`): the `Relay-Signature` header is `t=<unix seconds>,v1=<hex MAC>` over `<t>.<body>`, so the receiver checks both the body and its age with the same key, which the installation imports into the key store and gives the receiver. A `2xx` answer is accepted; anything else is an error and the caller sends the same body again.

  Options: `:url` (`https://…`; `http://` only outside production for a local receiver), `:hmac_label`, and for tests `:req_options`.
  """

  @timeout_ms 10_000
  @local_allowed Mix.env() != :prod
  @keys [:url, :hmac_label]
  @optional [:req_options]

  # TN-46
  # TN-49
  @doc "Validates the transport options; returns an error message for a missing, unknown or malformed option."
  @spec validate(keyword(), [atom()]) :: :ok | {:error, String.t()}
  def validate(opts, extra \\ []) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "options must be a keyword list"}

      (unknown = Keyword.keys(opts) -- (@keys ++ @optional ++ extra)) != [] ->
        {:error, "unknown options #{inspect(Enum.sort(unknown))}"}

      (missing = Enum.reject(@keys, &Keyword.has_key?(opts, &1))) != [] ->
        {:error, "missing options #{inspect(missing)}"}

      not url?(opts[:url]) ->
        {:error, "url must be an https:// URL"}

      not (is_binary(opts[:hmac_label]) and opts[:hmac_label] != "") ->
        {:error, "hmac_label must be a key store label"}

      true ->
        :ok
    end
  end

  defp url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        @local_allowed

      _ ->
        false
    end
  end

  defp url?(_url), do: false

  # TN-46
  # TN-49
  # TN-63
  @doc "The `Relay-Signature` header value of `body` sent at Unix second `t`, signed in the key store under `label`."
  @spec signature(Relay.Keys.label(), non_neg_integer(), binary()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def signature(label, t, body) when is_integer(t) and is_binary(body) do
    signed = Relay.Redacted.wrap(Integer.to_string(t) <> "." <> body)

    with {:ok, mac} <- Relay.Keys.hmac_sha256(label, signed),
         do: {:ok, "t=#{t},v1=" <> Base.encode16(mac, case: :lower)}
  end

  # TN-46
  # TN-49
  @doc "Sends a body of JSON lines to the target and accepts a `2xx` answer."
  @spec post(binary(), keyword()) :: :ok | {:error, Relay.Error.t()}
  def post(body, opts) when is_binary(body) do
    t = DateTime.to_unix(Relay.Clock.utc_now())

    with {:ok, signature} <- signature(Keyword.fetch!(opts, :hmac_label), t, body) do
      req =
        Req.new(
          [
            method: :post,
            url: Keyword.fetch!(opts, :url),
            headers: [
              {"content-type", "application/x-ndjson"},
              {"relay-signature", signature}
            ],
            body: body,
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: @timeout_ms,
            connect_options: [timeout: @timeout_ms]
          ] ++ Keyword.get(opts, :req_options, [])
        )

      :ok = Relay.NetworkGuard.check!(:http)
      answer(Req.request(req))
    end
  end

  defp answer({:ok, %{status: status}}) when status in 200..299, do: :ok

  defp answer({:ok, %{status: status}}),
    do: {:error, Relay.Error.new(:publication_refused, "target refused", %{status: status})}

  defp answer({:error, exception}) do
    {:error,
     Relay.Error.new(:publication_unreachable, "target unreachable", %{
       reason: inspect(exception.__struct__)
     })}
  end

  # TN-46
  @doc "A checkpoint as one JSON line."
  @spec checkpoint_line(Relay.Audit.Checkpointer.Publisher.checkpoint()) :: binary()
  def checkpoint_line(checkpoint) do
    Jason.encode!(%{
      "type" => "audit_checkpoint",
      "id" => Relay.Id.to_string(checkpoint.id),
      "origin" => checkpoint.origin,
      "tree_size" => checkpoint.tree_size,
      "root_hash" => Base.encode64(checkpoint.root_hash),
      "signed_note" => checkpoint.signed_note,
      "key_ref" => checkpoint.key_ref,
      "heartbeat" => checkpoint.heartbeat
    }) <> "\n"
  end

  # TN-49
  @doc "An audit record as one JSON line, with its log origin and leaf index."
  @spec record_line(String.t(), map()) :: binary()
  def record_line(origin, record) do
    Jason.encode!(%{
      "type" => "audit_record",
      "origin" => origin,
      "leaf_index" => record.leaf_index,
      "id" => Relay.Id.to_string(record.id),
      "tenant_id" => Relay.ExternalId.encode("ten", record.tenant_id),
      "environment" => record.environment,
      "created_at" => DateTime.to_iso8601(record.created_at),
      "action" => record.action,
      "actor_kind" => record.actor_kind,
      "actor_ref" => record.actor_ref,
      "on_behalf_of_ref" => record.on_behalf_of_ref,
      "access_record_ref" => record.access_record_ref,
      "target_type" => record.target_type,
      "target_id" => record.target_id,
      "reason" => record.reason,
      "record_digest" => Base.encode16(record.record_digest, case: :lower)
    }) <> "\n"
  end
end
