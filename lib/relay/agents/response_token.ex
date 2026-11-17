defmodule Relay.Agents.ResponseToken do
  @moduledoc """
  The bearer response token of a waitpoint (AG-31, L-36, INV-33). The right to respond is bound to the responder's identity; a bearer is minted only where a human channel needs one (a link in an SMS or an e-mail, a button of a messaging channel). A token names one waitpoint and one responder, is used once and lives shortly: at most `x-relay-limits.waitpoint.response_token_ttl` and never past the waitpoint's deadline. Minting a token again for the same responder (a resend) rotates the earlier unused one, which is refused from then on. A waitpoint of the profile `guardian_approval` takes no token: it closes only on the Access approval surface (AG-62, AG-32).

  The token is `rt1.` followed by the base64url payload (tenant, environment and token identifier) and the base64url HMAC-SHA256 over it, computed inside the key store under the installation's cursor key with its own domain separation prefix. Everything else (the waitpoint, the responder, the expiry, the use) is the token's row, so a forged, moved or reused token is refused. The token is handed only to the sender of a human channel message; it is never part of anything returned to the waiter (AG-30).
  """

  alias Relay.Agents.ResponseIntake
  alias Relay.Agents.ResponseStore
  alias Relay.Redacted

  @domain "relay-response-token-v1\n"
  @environments %{live: 1, test: 2}
  @by_byte %{1 => :live, 2 => :test}
  @ttl_ms Relay.Limits.seconds!(["waitpoint", "response_token_ttl"]) * 1000

  @type claims :: %{scope: Relay.Scope.t(), id: Relay.Id.t()}
  @type consumption :: %{
          via: String.t(),
          value_ct: binary(),
          value_key_id: Relay.Id.t(),
          value_digest: <<_::256>>
        }
  @type refusal :: :invalid | :expired | :rotated | :already_consumed

  # AG-31
  # INV-33
  # AG-62
  @doc "Mints the response token of a responder of an open question or review and rotates the responder's earlier unused token; called outside any transaction. A refusal is `:not_found`, `:not_open`, `:not_responder` or `:profile_refused`."
  @spec mint(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def mint(%Relay.Scope{} = scope, <<_::128>> = waitpoint_id, <<_::128>> = recipient_id) do
    id = Relay.Id.generate()

    with {:ok, token} <- sign(scope, id),
         {:ok, minted} <- record(scope, id, waitpoint_id, recipient_id) do
      case minted do
        {:minted, expires_at} -> {:ok, %{token: token, expires_at: expires_at}}
        {refusal, _expires_at} -> {:error, refusal}
      end
    end
  end

  defp record(scope, id, waitpoint_id, recipient_id) do
    ResponseStore.in_scope(scope, fn _status ->
      ResponseStore.token_mint(id, waitpoint_id, recipient_id, @ttl_ms)
    end)
  end

  defp sign(scope, id) do
    env = Map.fetch!(@environments, scope.environment)
    payload = <<scope.tenant_id::binary-16, env, id::binary-16>>

    with {:ok, mac} <- mac(payload) do
      {:ok, "rt1." <> encode(payload) <> "." <> encode(mac)}
    end
  end

  # AG-31
  @doc "Verifies the MAC of a token in constant time and returns the scope and the token identifier it names; nothing is consumed."
  @spec verify(term()) :: {:ok, claims()} | {:error, :invalid | Relay.Error.t()}
  def verify(token) when is_binary(token) and byte_size(token) <= 256 do
    with ["rt1", body, signature] <- String.split(token, "."),
         {:ok, payload} <- Base.url_decode64(body, padding: false),
         {:ok, <<_::binary-32>> = given} <- Base.url_decode64(signature, padding: false),
         <<tenant::binary-16, env, id::binary-16>> <- payload,
         {:ok, environment} <- Map.fetch(@by_byte, env),
         {:ok, mac} <- mac(payload),
         true <- :crypto.hash_equals(mac, given),
         {:ok, scope} <- Relay.Scope.new(tenant, environment) do
      {:ok, %{scope: scope, id: id}}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _invalid -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  # AG-31
  # AG-35
  @doc "Verifies a token and reads its row: the waitpoint, the responder, the state (`issued`, `processing`, `settled` or `rotated`), the expiry, the digest of the response it was used with and the outcome; nothing is consumed."
  @spec peek(term()) :: {:ok, map()} | {:error, :invalid | term()}
  def peek(token) do
    with {:ok, %{scope: scope, id: id}} <- verify(token),
         {:ok, row} <- ResponseStore.in_scope(scope, fn _status -> ResponseStore.token(id) end) do
      case row do
        nil -> {:error, :invalid}
        row -> {:ok, Map.put(row, :scope, scope)}
      end
    else
      {:error, %Relay.Error{code: :not_found}} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  # AG-31
  # AG-35
  # INV-33
  @doc "Verifies a token and consumes it with the sealed response it carries, in one transaction with the job that offers the response to the waitpoint. A token is consumed once: `{:ok, :consumed, claims}` the first time and `{:ok, :replayed, claims}` when the same response is sent again; a forged or unknown token is `:invalid`, and a used, rotated or expired one is refused with its reason."
  @spec verify_and_consume(term(), consumption()) ::
          {:ok, :consumed | :replayed, claims()} | {:error, refusal() | term()}
  def verify_and_consume(token, %{via: via, value_ct: ct, value_key_id: key} = consumption) do
    with {:ok, %{scope: scope, id: id} = claims} <- verify(token),
         {:ok, result} <- consume(scope, id, via, ct, key, consumption.value_digest) do
      case result do
        used when used in [:consumed, :replayed] -> {:ok, used, claims}
        :not_found -> {:error, :invalid}
        refusal -> {:error, refusal}
      end
    else
      {:error, %Relay.Error{code: :not_found}} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume(scope, id, via, ct, key, digest) do
    ResponseStore.in_scope(scope, fn _status ->
      {result, _waitpoint, _recipient} = ResponseStore.token_consume(id, via, ct, key, digest)
      if result == :consumed, do: :ok = queue(scope, id)
      result
    end)
  end

  defp queue(scope, id) do
    args = scope |> Relay.Scope.to_job_args() |> Map.put("token_id", Relay.Id.to_string(id))

    case Oban.insert(ResponseIntake.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> raise ArgumentError, "response intake not queued: #{inspect(reason)}"
    end
  end

  defp mac(payload) do
    with {:ok, label} <- Relay.Keys.cursor_label() do
      Relay.Keys.hmac_sha256(label, Redacted.wrap(@domain <> payload))
    end
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
