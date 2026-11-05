defmodule Relay.Channels.Inbound do
  @moduledoc """
  The common verifier of inbound provider webhooks (T-40, TN-35, CH-3), reused by every adapter. Verification runs on the raw request body, before it is parsed, with constant-time comparison; a signed timestamp must lie within the tolerance of `now` (300 seconds unless `:tolerance_s` says otherwise). Headers are the request's `{name, value}` pairs with lower-case names, as Plug gives them. Nothing here reads a clock: the caller passes `now`.

    * `standard_webhooks/4`: Standard Webhooks, `webhook-id`, `webhook-timestamp` and `webhook-signature` over `id.timestamp.body`, `v1` HMAC-SHA256 with a `whsec_` secret or `v1a` Ed25519 with a `whpk_` public key.
    * `hmac/4`: an HMAC-SHA256 signature of the body in one header, hex or Base64, with an optional prefix, such as Meta's `X-Hub-Signature-256: sha256=<hex>` (CH-60).
    * `slack/4`: Slack's `v0` signature over `v0:timestamp:body` (CH-62).
    * `ed25519/4`: an Ed25519 signature of the body, or of a timestamp header followed by the body.
    * `jwt/3`: a JWT signed with HS256, RS256 or ES256 whose `exp` and `nbf` hold at `now`; returns its claims.
    * `secret_token/3`: a compensating control, a shared token in a header compared in constant time, such as Telegram's secret token; its authenticity is declared `unverifiable` (§12.1.2).
  """

  @tolerance_s 300

  @type headers :: [{String.t(), String.t()}]
  @type reason :: :missing_header | :bad_signature | :stale_timestamp | :bad_timestamp
  @type signature_reason :: :missing_header | :bad_signature
  @type key :: Relay.Redacted.t()

  # T-40
  # TN-35
  @doc "Verifies a Standard Webhooks request. `key` is the endpoint secret (`whsec_…`, `v1`) or public key (`whpk_…`, `v1a`)."
  @spec standard_webhooks(key(), binary(), headers(), DateTime.t()) :: :ok | {:error, reason()}
  def standard_webhooks(key, body, headers, %DateTime{} = now) when is_binary(body) do
    with {:ok, id} <- header(headers, "webhook-id"),
         {:ok, timestamp} <- header(headers, "webhook-timestamp"),
         {:ok, signatures} <- header(headers, "webhook-signature"),
         :ok <- fresh(timestamp, now, @tolerance_s) do
      payload = id <> "." <> timestamp <> "." <> body
      signed = String.split(signatures, " ", trim: true)

      if Enum.any?(signed, &signature?(key, payload, &1)), do: :ok, else: {:error, :bad_signature}
    end
  end

  defp signature?(key, payload, "v1," <> signature) do
    with "whsec_" <> encoded <- Relay.Redacted.expose(key),
         {:ok, secret} <- Base.decode64(encoded),
         {:ok, given} <- Base.decode64(signature) do
      Relay.Crypto.secure_compare(:crypto.mac(:hmac, :sha256, secret, payload), given)
    else
      _invalid -> false
    end
  end

  defp signature?(key, payload, "v1a," <> signature) do
    with "whpk_" <> encoded <- Relay.Redacted.expose(key),
         {:ok, public} <- Base.decode64(encoded),
         {:ok, given} <- Base.decode64(signature) do
      ed25519?(public, payload, given)
    else
      _invalid -> false
    end
  end

  defp signature?(_key, _payload, _other), do: false

  # T-40
  # CH-60
  @doc "Verifies an HMAC-SHA256 signature of the raw body in `header`. Options: `:prefix` (such as `\"sha256=\"`) and `:encoding` (`:hex`, the default, or `:base64`)."
  @spec hmac(key(), binary(), headers(), keyword()) :: :ok | {:error, signature_reason()}
  def hmac(key, body, headers, opts) when is_binary(body) do
    header_name = Keyword.fetch!(opts, :header)
    prefix = Keyword.get(opts, :prefix, "")

    with {:ok, value} <- header(headers, header_name),
         {:ok, given} <- strip(value, prefix),
         {:ok, decoded} <- decode(given, Keyword.get(opts, :encoding, :hex)) do
      mac = :crypto.mac(:hmac, :sha256, Relay.Redacted.expose(key), body)
      if Relay.Crypto.secure_compare(mac, decoded), do: :ok, else: {:error, :bad_signature}
    end
  end

  # T-40
  # CH-62
  @doc "Verifies Slack's `v0` request signature (`x-slack-signature`, `x-slack-request-timestamp`) with the signing secret."
  @spec slack(key(), binary(), headers(), DateTime.t()) :: :ok | {:error, reason()}
  def slack(key, body, headers, %DateTime{} = now) when is_binary(body) do
    with {:ok, timestamp} <- header(headers, "x-slack-request-timestamp"),
         {:ok, value} <- header(headers, "x-slack-signature"),
         :ok <- fresh(timestamp, now, @tolerance_s),
         {:ok, given} <- strip(value, "v0="),
         {:ok, decoded} <- decode(given, :hex) do
      payload = "v0:" <> timestamp <> ":" <> body
      mac = :crypto.mac(:hmac, :sha256, Relay.Redacted.expose(key), payload)
      if Relay.Crypto.secure_compare(mac, decoded), do: :ok, else: {:error, :bad_signature}
    end
  end

  # T-40
  @doc "Verifies an Ed25519 signature in `header` with the provider's raw 32-byte public key. Options: `:header` (required), `:encoding` (`:hex`, the default, or `:base64`) and `:timestamp_header`, whose value is signed before the body and must be fresh at `:now`."
  @spec ed25519(key(), binary(), headers(), keyword()) :: :ok | {:error, reason()}
  def ed25519(key, body, headers, opts) when is_binary(body) do
    with {:ok, value} <- header(headers, Keyword.fetch!(opts, :header)),
         {:ok, signature} <- decode(value, Keyword.get(opts, :encoding, :hex)),
         {:ok, prefix} <- signed_timestamp(headers, opts) do
      if ed25519?(Relay.Redacted.expose(key), prefix <> body, signature),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  defp signed_timestamp(headers, opts) do
    case Keyword.get(opts, :timestamp_header) do
      nil ->
        {:ok, ""}

      name ->
        with {:ok, timestamp} <- header(headers, name),
             :ok <- fresh(timestamp, Keyword.fetch!(opts, :now), @tolerance_s),
             do: {:ok, timestamp}
    end
  end

  defp ed25519?(<<_::256>> = public, payload, <<_::512>> = signature),
    do: :crypto.verify(:eddsa, :none, payload, signature, [public, :ed25519])

  defp ed25519?(_public, _payload, _signature), do: false

  # T-40
  # TN-35
  @doc """
  Verifies a compact JWS token and returns its claims. `key` is the HMAC secret for HS256 or a PEM public key for RS256 and ES256; `opts` names the accepted `:algs` (required, never `none`) and the `:now` at which `exp` and `nbf` must hold, with `:leeway_s` (default 60).
  """
  @spec jwt(key(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :bad_signature | :stale_timestamp}
  def jwt(key, token, opts) when is_binary(token) do
    algs = Keyword.fetch!(opts, :algs) -- ["none"]

    with [h, p, s] <- String.split(token, "."),
         {:ok, %{"alg" => alg}} <- part(h),
         true <- alg in algs,
         {:ok, signature} <- Base.url_decode64(s, padding: false),
         true <- jws?(alg, Relay.Redacted.expose(key), h <> "." <> p, signature),
         {:ok, %{} = claims} <- part(p),
         :ok <- times(claims, Keyword.fetch!(opts, :now), Keyword.get(opts, :leeway_s, 60)) do
      {:ok, claims}
    else
      {:error, :stale_timestamp} -> {:error, :stale_timestamp}
      _invalid -> {:error, :bad_signature}
    end
  end

  defp part(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, %{} = map} <- Jason.decode(json) do
      {:ok, map}
    else
      _invalid -> :error
    end
  end

  defp jws?("HS256", secret, input, signature),
    do: Relay.Crypto.secure_compare(:crypto.mac(:hmac, :sha256, secret, input), signature)

  defp jws?("RS256", pem, input, signature) do
    case public_key(pem) do
      {:ok, key} -> :public_key.verify(input, :sha256, signature, key)
      :error -> false
    end
  end

  defp jws?("ES256", pem, input, <<r::unsigned-256, s::unsigned-256>>) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    case public_key(pem) do
      {:ok, key} -> :public_key.verify(input, :sha256, der, key)
      :error -> false
    end
  end

  defp jws?(_alg, _key, _input, _signature), do: false

  defp public_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> :error
    end
  rescue
    _invalid -> :error
  end

  defp public_key(_pem), do: :error

  defp times(claims, %DateTime{} = now, leeway) do
    t = DateTime.to_unix(now)
    exp = Map.get(claims, "exp")
    nbf = Map.get(claims, "nbf")

    cond do
      is_integer(exp) and t > exp + leeway -> {:error, :stale_timestamp}
      is_integer(nbf) and t < nbf - leeway -> {:error, :stale_timestamp}
      true -> :ok
    end
  end

  # CH-62
  @doc "Checks a shared secret token in `header` in constant time: a compensating control whose authenticity is declared unverifiable."
  @spec secret_token(key(), headers(), String.t()) :: :ok | {:error, signature_reason()}
  def secret_token(key, headers, header_name) do
    with {:ok, value} <- header(headers, header_name) do
      if Relay.Crypto.secure_compare(value, Relay.Redacted.expose(key)),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :missing_header}
    end
  end

  defp strip(value, prefix) do
    if String.starts_with?(value, prefix),
      do: {:ok, binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))},
      else: {:error, :bad_signature}
  end

  defp decode(value, :hex) do
    case Base.decode16(value, case: :mixed) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :bad_signature}
    end
  end

  defp decode(value, :base64) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :bad_signature}
    end
  end

  defp fresh(timestamp, %DateTime{} = now, tolerance) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        if abs(DateTime.to_unix(now) - seconds) <= tolerance,
          do: :ok,
          else: {:error, :stale_timestamp}

      _invalid ->
        {:error, :bad_timestamp}
    end
  end
end
