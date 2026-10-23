defmodule Relay.Keys.Protocol do
  @moduledoc """
  Version 1 of the PKCS#11 Port request and response protocol. A frame is `version, request id, opcode or status`, followed by length-prefixed fields; `{:packet, 4}` carries the frame length.
  """

  alias Relay.Error
  alias Relay.Redacted

  @version 1

  @type request ::
          :ping
          | {:sign, Relay.Keys.alg(), binary(), binary()}
          | {:public_key, Relay.Keys.alg(), binary()}
          | {:wrap, binary(), binary(), binary()}
          | {:unwrap, binary(), binary(), binary()}
          | {:hmac, binary(), binary()}
          | {:read_secret, binary()}

  @type kind ::
          :ping
          | {:sign, Relay.Keys.alg()}
          | {:public_key, Relay.Keys.alg()}
          | :wrap
          | :unwrap
          | :hmac
          | :read_secret

  @type result ::
          :ok | {:ok, binary() | Relay.Keys.public_key() | Redacted.t()} | {:error, Error.t()}

  # TN-63
  @doc "Encodes a request frame."
  @spec encode(non_neg_integer(), request()) :: iodata()
  def encode(id, :ping), do: header(id, 0)

  def encode(id, {:sign, alg, label, message}),
    do: [header(id, 1), alg(alg), field(label), field(message)]

  def encode(id, {:public_key, alg, label}), do: [header(id, 2), alg(alg), field(label)]

  def encode(id, {:wrap, label, aad, plaintext}),
    do: [header(id, 3), field(label), field(aad), field(plaintext)]

  def encode(id, {:unwrap, label, aad, wrapped}),
    do: [header(id, 4), field(label), field(aad), field(wrapped)]

  def encode(id, {:hmac, label, message}), do: [header(id, 5), field(label), field(message)]

  def encode(id, {:read_secret, label}), do: [header(id, 6), field(label)]

  @doc "Returns the response shape expected for a request."
  @spec kind(request()) :: kind()
  def kind(:ping), do: :ping
  def kind({:sign, alg, _, _}), do: {:sign, alg}
  def kind({:public_key, alg, _}), do: {:public_key, alg}
  def kind({:wrap, _, _, _}), do: :wrap
  def kind({:unwrap, _, _, _}), do: :unwrap
  def kind({:hmac, _, _}), do: :hmac
  def kind({:read_secret, _}), do: :read_secret

  @doc "Decodes a response frame into its request id, status byte and fields."
  @spec decode(binary()) ::
          {:ok, non_neg_integer(), non_neg_integer(), [binary()]} | {:error, Error.t()}
  def decode(<<@version, id::32, status, rest::binary>>) do
    case fields(rest, []) do
      {:ok, fields} -> {:ok, id, status, fields}
      :error -> malformed()
    end
  end

  def decode(_frame), do: malformed()

  @doc "Turns a decoded response into the typed result for a request kind; unwrapped key material and secrets come back redacted."
  @spec result(kind(), non_neg_integer(), [binary()]) :: result()
  def result(:ping, 0, []), do: :ok
  def result({:sign, _alg}, 0, [signature]), do: {:ok, signature}
  def result({:public_key, :rs256}, 0, [modulus, exponent]), do: {:ok, {modulus, exponent}}
  def result({:public_key, _alg}, 0, [point]), do: {:ok, point}
  def result(:wrap, 0, [wrapped]), do: {:ok, wrapped}
  def result(:unwrap, 0, [plaintext]), do: {:ok, Redacted.wrap(plaintext)}
  def result(:hmac, 0, [<<_::256>> = mac]), do: {:ok, mac}
  def result(:read_secret, 0, [secret]), do: {:ok, Redacted.wrap(secret)}
  def result(_kind, 0, _fields), do: malformed()

  def result(_kind, status, [message]) when status in 1..6 and is_binary(message),
    do: {:error, Error.new(code(status), "key store: " <> message)}

  def result(_kind, _status, _fields), do: malformed()

  defp header(id, op), do: <<@version, id::32, op>>

  defp alg(:es256), do: <<1>>
  defp alg(:rs256), do: <<2>>
  defp alg(:ed25519), do: <<3>>

  defp field(bytes), do: [<<byte_size(bytes)::32>>, bytes]

  defp fields(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp fields(<<len::32, value::binary-size(len), rest::binary>>, acc),
    do: fields(rest, [value | acc])

  defp fields(_rest, _acc), do: :error

  defp code(1), do: :key_store_bad_request
  defp code(2), do: :key_store_version
  defp code(3), do: :key_not_found
  defp code(4), do: :key_integrity
  defp code(5), do: :key_store_token
  defp code(6), do: :key_store_internal

  defp malformed, do: {:error, Error.new(:key_store_protocol, "malformed key store response")}
end
