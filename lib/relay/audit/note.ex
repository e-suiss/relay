defmodule Relay.Audit.Note do
  @moduledoc """
  C2SP `signed-note` with Ed25519 signatures and the C2SP `tlog-checkpoint` body. A note is UTF-8 text ending in a newline, followed by an empty line and signature lines `— <key name> base64(key id ‖ signature)`. The Ed25519 key id is the first four bytes of `SHA-256(key name ‖ 0x0A ‖ 0x01 ‖ public key)`; a verifier key is written `<key name>+<hex key id>+base64(0x01 ‖ public key)`.
  """

  alias Relay.Error

  @ed25519 1
  @dash "— "

  @type public_key :: <<_::256>>
  @type verifier :: %{name: String.t(), key_id: <<_::32>>, public_key: public_key()}
  @type checkpoint :: %{
          origin: String.t(),
          tree_size: non_neg_integer(),
          root_hash: <<_::256>>,
          extensions: [String.t()]
        }

  # OP-63
  # TN-46
  @doc "Returns true if `name` is a valid key name: non-empty, no whitespace and no `+`."
  @spec valid_key_name?(term()) :: boolean()
  def valid_key_name?(name) when is_binary(name),
    do: name != "" and String.valid?(name) and not Regex.match?(~r/[\s+]/u, name)

  def valid_key_name?(_name), do: false

  @doc "Computes the Ed25519 key id of a key name and public key."
  @spec key_id(String.t(), public_key()) :: <<_::32>>
  def key_id(name, <<_::256>> = public_key) do
    <<id::binary-4, _::binary>> = :crypto.hash(:sha256, [name, ?\n, @ed25519, public_key])
    id
  end

  @doc "Encodes the verifier key of a key name and Ed25519 public key."
  @spec verifier_key(String.t(), public_key()) :: String.t()
  def verifier_key(name, <<_::256>> = public_key) do
    true = valid_key_name?(name)

    Enum.join(
      [
        name,
        Base.encode16(key_id(name, public_key), case: :lower),
        Base.encode64(<<@ed25519, public_key::binary>>)
      ],
      "+"
    )
  end

  @doc "Parses a verifier key; only Ed25519 keys are accepted and the key id must match."
  @spec parse_verifier_key(String.t()) :: {:ok, verifier()} | {:error, Error.t()}
  def parse_verifier_key(text) when is_binary(text) do
    with [name, hex, b64] <- String.split(text, "+"),
         true <- valid_key_name?(name),
         {:ok, <<_::binary-4>> = id} <- Base.decode16(hex, case: :lower),
         {:ok, <<@ed25519, public_key::binary-32>>} <- Base.decode64(b64),
         true <- key_id(name, public_key) == id do
      {:ok, %{name: name, key_id: id, public_key: public_key}}
    else
      _ -> {:error, Error.new(:invalid_verifier_key, "not an Ed25519 signed-note verifier key")}
    end
  end

  @doc "Formats the body of a C2SP checkpoint: origin, decimal tree size and base64 root hash, each followed by a newline."
  @spec checkpoint_text(String.t(), non_neg_integer(), <<_::256>>) :: String.t()
  def checkpoint_text(origin, tree_size, <<_::256>> = root_hash)
      when is_binary(origin) and origin != "" and is_integer(tree_size) and tree_size >= 0 do
    true = String.valid?(origin) and not String.contains?(origin, "\n")
    "#{origin}\n#{tree_size}\n#{Base.encode64(root_hash)}\n"
  end

  @doc "Parses a C2SP checkpoint body."
  @spec parse_checkpoint(String.t()) :: {:ok, checkpoint()} | {:error, Error.t()}
  def parse_checkpoint(text) when is_binary(text) do
    with true <- String.ends_with?(text, "\n"),
         [origin, size, root | extensions] <- text |> String.trim_trailing("\n") |> lines(),
         true <- Enum.all?([origin, size, root | extensions], &(&1 != "")),
         {tree_size, ""} when tree_size >= 0 <- parse_decimal(size),
         {:ok, <<_::256>> = root_hash} <- Base.decode64(root) do
      {:ok, %{origin: origin, tree_size: tree_size, root_hash: root_hash, extensions: extensions}}
    else
      _ -> {:error, Error.new(:invalid_checkpoint, "not a C2SP checkpoint body")}
    end
  end

  defp parse_decimal("0"), do: {0, ""}
  defp parse_decimal(<<d, _::binary>> = text) when d in ?1..?9, do: Integer.parse(text)
  defp parse_decimal(_text), do: :error

  @doc "Signs note text with `sign_fun`, which receives the exact text bytes and returns a 64-byte Ed25519 signature."
  @spec sign(String.t(), String.t(), public_key(), (binary() ->
                                                      {:ok, binary()} | {:error, Error.t()})) ::
          {:ok, String.t()} | {:error, Error.t()}
  def sign(text, name, <<_::256>> = public_key, sign_fun) when is_function(sign_fun, 1) do
    with :ok <- valid_text(text),
         true <-
           valid_key_name?(name) || {:error, Error.new(:invalid_key_name, "invalid key name")},
         {:ok, <<_::binary-64>> = signature} <- sign_fun.(text) do
      {:ok, text <> "\n" <> signature_line(name, key_id(name, public_key), signature)}
    else
      {:ok, _other} ->
        {:error, Error.new(:invalid_signature, "signer returned a malformed signature")}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc "Formats one signature line."
  @spec signature_line(String.t(), <<_::32>>, binary()) :: String.t()
  def signature_line(name, <<_::binary-4>> = key_id, signature) when is_binary(signature),
    do: @dash <> name <> " " <> Base.encode64(key_id <> signature) <> "\n"

  @doc """
  Opens a signed note: returns the text and the names of the given verifiers whose signatures verify. Signatures by unknown keys are ignored; a note with no verified signature, a bad signature by a known key or malformed syntax is an error.
  """
  @spec open(String.t(), [verifier()]) :: {:ok, String.t(), [String.t()]} | {:error, Error.t()}
  def open(note, verifiers) when is_binary(note) and is_list(verifiers) do
    with {:ok, text, signatures} <- split(note),
         {:ok, names} <- verify_all(text, signatures, verifiers) do
      {:ok, text, names}
    end
  end

  defp split(note) do
    with true <- String.valid?(note) and String.ends_with?(note, "\n"),
         [text, block] <- split_last(note),
         {:ok, signatures} <- parse_signatures(block) do
      {:ok, text, signatures}
    else
      {:error, %Error{}} = error -> error
      _ -> malformed()
    end
  end

  defp split_last(note) do
    case :binary.matches(note, "\n\n") do
      [] ->
        :error

      matches ->
        {at, _} = List.last(matches)
        [binary_part(note, 0, at + 1), binary_part(note, at + 2, byte_size(note) - at - 2)]
    end
  end

  defp parse_signatures(block) do
    block
    |> String.trim_trailing("\n")
    |> lines()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      with @dash <> rest <- line,
           [name, b64] <- String.split(rest, " "),
           true <- valid_key_name?(name),
           {:ok, <<id::binary-4, signature::binary>>} <- Base.decode64(b64) do
        {:cont, {:ok, [{name, id, signature} | acc]}}
      else
        _ -> {:halt, malformed()}
      end
    end)
    |> case do
      {:ok, []} -> malformed()
      {:ok, signatures} -> {:ok, Enum.reverse(signatures)}
      error -> error
    end
  end

  defp verify_all(text, signatures, verifiers) do
    Enum.reduce_while(signatures, {:ok, []}, fn {name, _id, _sig} = signature, {:ok, names} ->
      case verify_one(text, signature, verifiers) do
        :unknown -> {:cont, {:ok, names}}
        :ok -> {:cont, {:ok, names ++ [name]}}
        :bad -> {:halt, {:error, Error.new(:invalid_signature, "note signature does not verify")}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, Error.new(:unverified_note, "no known key signed the note")}
      {:ok, names} -> {:ok, Enum.uniq(names)}
      error -> error
    end
  end

  defp verify_one(text, {name, id, signature}, verifiers) do
    case Enum.find(verifiers, &(&1.name == name and &1.key_id == id)) do
      nil ->
        :unknown

      verifier ->
        if byte_size(signature) == 64 and
             :crypto.verify(:eddsa, :none, text, signature, [verifier.public_key, :ed25519]),
           do: :ok,
           else: :bad
    end
  end

  defp valid_text(text) do
    if is_binary(text) and String.valid?(text) and String.ends_with?(text, "\n") and
         not String.contains?(text, "\n\n") and not String.starts_with?(text, "\n"),
       do: :ok,
       else:
         {:error,
          Error.new(:invalid_note, "note text must be non-empty lines ending in a newline")}
  end

  defp lines(text), do: String.split(text, "\n")

  defp malformed, do: {:error, Error.new(:malformed_note, "malformed signed note")}
end
