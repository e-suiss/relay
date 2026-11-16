defmodule Relay.Delivery.Exports.Link do
  @moduledoc """
  The signed download link of a ready export (DS-37). The token names the tenant, the environment, the export and the moment the link expires, and carries an HMAC-SHA256 over them computed inside the key store under the installation's cursor key with its own domain separation prefix, so a link cannot be forged, moved to another export or scope, or extended. The link expires with the export; the download itself checks the export again and is audited.

  The token is `v1.` followed by the base64url payload and the base64url MAC.
  """

  alias Relay.Redacted

  @domain "relay-export-link-v1\n"
  @environments %{live: 1, test: 2}
  @by_byte %{1 => :live, 2 => :test}

  @type claims :: %{scope: Relay.Scope.t(), id: Relay.Id.t(), expires_at: DateTime.t()}

  # DS-37
  @doc "Signs the download token of an export of `scope` that expires at `expires_at`."
  @spec sign(Relay.Scope.t(), Relay.Id.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def sign(%Relay.Scope{} = scope, <<_::128>> = id, %DateTime{} = expires_at) do
    env = Map.fetch!(@environments, scope.environment)
    at = DateTime.to_unix(expires_at)
    payload = <<scope.tenant_id::binary-16, env, id::binary-16, at::64>>

    with {:ok, mac} <- mac(payload) do
      {:ok, "v1." <> encode(payload) <> "." <> encode(mac)}
    end
  end

  # DS-37
  @doc "Verifies a download token: its MAC in constant time and its expiry against `now`; returns the claims or `:invalid`, `:expired` or a key store error."
  @spec verify(String.t(), DateTime.t()) ::
          {:ok, claims()} | {:error, :invalid | :expired | Relay.Error.t()}
  def verify(token, %DateTime{} = now) when is_binary(token) do
    with ["v1", body, signature] <- String.split(token, "."),
         {:ok, payload} <- Base.url_decode64(body, padding: false),
         {:ok, <<_::binary-32>> = given} <- Base.url_decode64(signature, padding: false),
         <<tenant::binary-16, env, id::binary-16, at::64>> <- payload,
         {:ok, environment} <- Map.fetch(@by_byte, env),
         {:ok, mac} <- mac(payload),
         true <- :crypto.hash_equals(mac, given),
         {:ok, scope} <- Relay.Scope.new(tenant, environment) do
      expires_at = DateTime.from_unix!(at)

      if DateTime.compare(expires_at, now) == :gt,
        do: {:ok, %{scope: scope, id: id, expires_at: expires_at}},
        else: {:error, :expired}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _invalid -> {:error, :invalid}
    end
  end

  def verify(_token, _now), do: {:error, :invalid}

  defp mac(payload) do
    with {:ok, label} <- Relay.Keys.cursor_label() do
      Relay.Keys.hmac_sha256(label, Redacted.wrap(@domain <> payload))
    end
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
