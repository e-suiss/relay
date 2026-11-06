defmodule Relay.Access.Pep do
  @moduledoc """
  Relay's policy enforcement point at the Access decision point (E-102, Access OP-149 m.24 (d)). Access takes an AuthZEN evaluation (`POST /access/v1/evaluation`) only over mutual TLS with a PEP client certificate, and addresses its decision receipt to that certificate's `x5t#S256`.

  * The PEP key is the P-256 key `access-pep` of the key store (`config :relay, Relay.Access, pep_key: label`) and never leaves the token (TN-63). The TLS client's CertificateVerify signature is made by `sign_handshake/3`, the `sign_fun` of the `:ssl` client key, through `Relay.Keys.sign/3` and the PKCS#11 port.
  * `csr/0` builds a PKCS#10 request for that key (`CN=relay-pep`), signed in the key store; `print_csr/0` prints it as PEM (`bin/relay eval 'Relay.Access.Pep.print_csr()'`, or `mix relay.access.pep_csr` in development). Access issues the certificate: locally its `init` signs the request with the PEP profile, in production the operator CA does.
  * The certificate, leaf first with any intermediates, is read from `pep_certificate` (`RELAY_ACCESS_PEP_CERT_FILE`); Access's server certificate is verified against `ca_certificates` (`RELAY_ACCESS_CA_FILE`). A certificate whose public key is not the PEP key is refused before any call. Both files are read again ten minutes later, so a renewed certificate is used without a restart.
  * `evaluate/3` posts one evaluation over TLS 1.3 and returns the decision with its `context` and, when Access signed one, its receipt as Access sends it: `sign1`, the COSE_Sign1, and `excerpt`, the key excerpt, both base64url.

  A 200 answer with a boolean `decision` is a decision; any other answer, a transport or handshake failure and a key store failure are `access_unreachable`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Http

  @credential {__MODULE__, :credential}
  @credential_ms 600_000
  @timeout_ms 5_000
  @subject "relay-pep"
  @ec_public_key <<0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01>>
  @prime256v1 <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>
  @ecdsa_sha256 <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02>>
  @common_name <<0x06, 0x03, 0x55, 0x04, 0x03>>

  @type receipt :: %{sign1: String.t(), excerpt: String.t()}
  @type decision :: %{decision: boolean(), context: map(), receipt: receipt() | nil}

  # E-102
  # E-27
  @doc "Posts one AuthZEN evaluation `body` to `url` over mutual TLS with Relay's PEP certificate. Options: `:http`, extra Req options."
  @spec evaluate(String.t(), map(), keyword()) :: {:ok, decision()} | {:error, Relay.Error.t()}
  def evaluate(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    with {:ok, credential} <- credential(),
         request = [
           url: url,
           method: :post,
           headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
           body: Jason.encode!(body),
           connect_options: [timeout: @timeout_ms, transport_opts: credential.transport]
         ],
         {:ok, response} <- Http.mtls_request(request ++ Keyword.get(opts, :http, [])),
         do: decided(response)
  end

  # E-102
  @doc "The `x5t#S256` of the configured PEP certificate: the name Access gives Relay's PEP and addresses its decision receipts to."
  @spec x5t() :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def x5t do
    with {:ok, credential} <- credential(), do: {:ok, credential.x5t}
  end

  # E-102
  # TN-63
  @doc "The `sign_fun` of the TLS client key: signs `message`, the CertificateVerify content, with ECDSA SHA-256 under the PEP key inside the key store and returns the DER signature TLS carries. A failure raises, which aborts the handshake."
  @spec sign_handshake(binary(), atom(), list()) :: binary()
  def sign_handshake(message, :sha256, _options) when is_binary(message) do
    case Relay.Keys.sign(:es256, pep_key(), message) do
      {:ok, <<r::256, s::256>>} -> ecdsa_der(r, s)
      _failed -> raise "Relay's PEP key cannot sign"
    end
  end

  # E-102
  @doc "A PKCS#10 certificate signing request (DER) for Relay's PEP key, `CN=relay-pep`, signed with ECDSA SHA-256 inside the key store."
  @spec csr() :: {:ok, binary()} | {:error, Relay.Error.t()}
  def csr do
    label = pep_key()

    with {:ok, <<4, _::binary-64>> = point} <- Relay.Keys.public_key(:es256, label),
         info = request_info(point),
         {:ok, <<r::256, s::256>>} <- Relay.Keys.sign(:es256, label, info) do
      {:ok, der(0x30, [info, der(0x30, @ecdsa_sha256), bit_string(ecdsa_der(r, s))])}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _other -> unreachable("Relay's PEP key is not a P-256 key")
    end
  end

  # E-102
  @doc "Prints the PEM certificate signing request of Relay's PEP key, to have Access or the operator CA issue its certificate; it starts the key store port when the node does not run it."
  @spec print_csr() :: :ok
  def print_csr do
    _started =
      Supervisor.start_link(Relay.Keys.children(),
        strategy: :one_for_one,
        max_restarts: 0,
        max_seconds: 1
      )

    case csr() do
      {:ok, der} -> IO.write(pem(der))
      {:error, error} -> raise error.message
    end
  end

  @doc "Forgets the cached PEP certificate and CA certificates, so the next call reads them again."
  @spec forget() :: :ok
  def forget, do: Cache.delete(@credential)

  defp decided(%Req.Response{status: 200, body: body}) do
    case Http.json(body) do
      {:ok, %{"decision" => decision} = answer, _raw} when is_boolean(decision) ->
        context = if is_map(answer["context"]), do: answer["context"], else: %{}
        {:ok, %{decision: decision, context: context, receipt: receipt(context["receipt"])}}

      {:ok, _answer, _raw} ->
        unreachable("the decision point answered without a decision")

      {:error, error} ->
        {:error, error}
    end
  end

  defp decided(%Req.Response{status: status}),
    do: unreachable("the decision point answered #{status}")

  defp receipt(%{"sign1" => sign1, "excerpt" => excerpt})
       when is_binary(sign1) and is_binary(excerpt),
       do: %{sign1: sign1, excerpt: excerpt}

  defp receipt(_none), do: nil

  defp credential do
    case Cache.fetch(@credential) do
      {:ok, credential} -> {:ok, credential}
      :miss -> load()
    end
  end

  defp load do
    with {:ok, [leaf | _] = chain} <- certificates(:pep_certificate, "the PEP certificate"),
         {:ok, cacerts} <- certificates(:ca_certificates, "the Access CA certificates"),
         :ok <- same_key(leaf) do
      credential = %{
        x5t: Base.url_encode64(:crypto.hash(:sha256, leaf), padding: false),
        transport: [
          cert: chain,
          key: %{algorithm: :ecdsa, sign_fun: &__MODULE__.sign_handshake/3},
          cacerts: cacerts,
          versions: [:"tlsv1.3"]
        ]
      }

      :ok = Cache.put(@credential, credential, @credential_ms)
      {:ok, credential}
    end
  end

  defp certificates(key, what) do
    with path when is_binary(path) and path != "" <- Keyword.get(Relay.Access.config(), key),
         {:ok, pem} <- File.read(path),
         [_ | _] = ders <- pem_certificates(pem) do
      {:ok, ders}
    else
      _missing -> unreachable(what <> " cannot be read")
    end
  end

  defp pem_certificates(pem) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  rescue
    _malformed -> []
  end

  defp pem(der), do: :public_key.pem_encode([{:CertificationRequest, der, :not_encrypted}])

  defp same_key(leaf) do
    with {:ok, point} <- Relay.Keys.public_key(:es256, pep_key()),
         ^point <- leaf_point(leaf) do
      :ok
    else
      {:error, %Relay.Error{}} -> unreachable("Relay's PEP key cannot be read")
      _other -> unreachable("the PEP certificate is not for Relay's PEP key")
    end
  end

  defp leaf_point(der) do
    {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)

    case elem(tbs, 7) do
      {:OTPSubjectPublicKeyInfo, _algorithm, {:ECPoint, point}} -> point
      _other -> nil
    end
  rescue
    _malformed -> nil
  end

  defp request_info(point) do
    name = der(0x30, der(0x31, der(0x30, [@common_name, der(0x0C, @subject)])))
    key = der(0x30, [der(0x30, [@ec_public_key, @prime256v1]), bit_string(point)])
    der(0x30, [<<0x02, 0x01, 0x00>>, name, key, <<0xA0, 0x00>>])
  end

  defp ecdsa_der(r, s),
    do: :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

  defp bit_string(bytes), do: der(0x03, [<<0>>, bytes])

  defp der(tag, content) do
    content = IO.iodata_to_binary(content)
    <<tag, der_length(byte_size(content))::binary, content::binary>>
  end

  defp der_length(size) when size < 0x80, do: <<size>>
  defp der_length(size) when size < 0x100, do: <<0x81, size>>
  defp der_length(size), do: <<0x82, size::16>>

  defp pep_key, do: Keyword.get(Relay.Access.config(), :pep_key, "access-pep")

  defp unreachable(message),
    do: {:error, Relay.Error.new(:access_unreachable, "Access decision point: " <> message)}
end
