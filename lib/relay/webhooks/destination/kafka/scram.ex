defmodule Relay.Webhooks.Destination.Kafka.Scram do
  @moduledoc """
  The client side of SCRAM-SHA-256 and SCRAM-SHA-512 (RFC 5802, RFC 7677) for the SASL exchange of a Kafka destination (WH-17), pure: the caller draws the nonce and moves the messages.

  No channel binding is used (`n,,`). The user name is written with `=` and `,` escaped; the password is used as its bytes, without the SASLprep profile. The server proves that it knows the password as well: `verify/2` compares its signature with the one computed here, and a server that cannot is not trusted.

  The iteration count comes from the server, so the caller bounds it with `max_iterations`. The password and the keys derived from it stay inside this module: the messages it returns carry only the proof.
  """

  @type hash :: :sha256 | :sha512

  @printable ~r/\A[\x21-\x2B\x2D-\x7E]+\z/
  @count ~r/\A[1-9][0-9]{0,8}\z/
  @header "biws"

  @doc "The first message of the client and its bare form, which the final message is computed over. `nonce` is printable text without a comma."
  @spec client_first(String.t(), String.t()) :: {message :: binary(), bare :: binary()}
  def client_first(username, nonce) when is_binary(username) and is_binary(nonce) do
    bare = "n=" <> escape(username) <> ",r=" <> nonce
    {"n,," <> bare, bare}
  end

  defp escape(username), do: username |> String.replace("=", "=3D") |> String.replace(",", "=2C")

  # WH-17
  @doc "The final message of the client for the server's first message, with the server signature the server's final message has to carry. `:error` when the server's message is not readable, does not continue the client's nonce or asks for more than `max_iterations`."
  @spec client_final(hash(), binary(), binary(), binary(), binary(), pos_integer()) ::
          {:ok, message :: binary(), server_signature :: binary()} | :error
  def client_final(hash, password, bare, server_first, nonce, max_iterations)
      when hash in [:sha256, :sha512] and is_binary(password) and is_binary(nonce) do
    with {:ok, combined, salt, iterations} <- challenge(server_first),
         true <- continues?(combined, nonce) and iterations <= max_iterations do
      {final, signature} = proof(hash, password, salt, iterations, bare, server_first, combined)
      {:ok, final, signature}
    else
      _refused -> :error
    end
  end

  defp challenge(server_first) do
    with ["r=" <> combined, "s=" <> salt, "i=" <> count | _extensions] <-
           String.split(server_first, ","),
         true <- Regex.match?(@printable, combined) and Regex.match?(@count, count),
         {:ok, salt} when salt != "" <- Base.decode64(salt) do
      {:ok, combined, salt, String.to_integer(count)}
    else
      _unreadable -> :error
    end
  end

  defp continues?(combined, nonce),
    do: byte_size(combined) > byte_size(nonce) and String.starts_with?(combined, nonce)

  defp proof(hash, password, salt, iterations, bare, server_first, combined) do
    salted = :crypto.pbkdf2_hmac(hash, password, salt, iterations, size(hash))
    client_key = :crypto.mac(:hmac, hash, salted, "Client Key")
    server_key = :crypto.mac(:hmac, hash, salted, "Server Key")
    unproved = "c=" <> @header <> ",r=" <> combined
    message = bare <> "," <> server_first <> "," <> unproved
    signature = :crypto.mac(:hmac, hash, :crypto.hash(hash, client_key), message)
    proof = :crypto.exor(client_key, signature)
    final = unproved <> ",p=" <> Base.encode64(proof)
    {final, :crypto.mac(:hmac, hash, server_key, message)}
  end

  defp size(:sha256), do: 32
  defp size(:sha512), do: 64

  # WH-17
  @doc "Checks the final message of the server against the expected server signature."
  @spec verify(binary(), binary()) :: :ok | :error
  def verify("v=" <> encoded, expected) when is_binary(expected) do
    signature = encoded |> String.split(",") |> hd() |> Base.decode64()

    case signature do
      {:ok, given} when byte_size(given) == byte_size(expected) -> equal(given, expected)
      _other -> :error
    end
  end

  def verify(_server_final, _expected), do: :error

  defp equal(given, expected) do
    if :crypto.hash_equals(given, expected), do: :ok, else: :error
  end
end
