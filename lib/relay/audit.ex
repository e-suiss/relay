defmodule Relay.Audit do
  @moduledoc """
  The audit log and its checkpoints. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Audit.Merkle
  alias Relay.Audit.Note
  alias Relay.Audit.Record

  @type hash :: Merkle.hash()

  # TN-46
  # TN-50
  @doc "Computes the record digest that an audit-writing function receives; see `Relay.Audit.Record.digest/1`."
  @spec record_digest(Record.t()) :: <<_::256>>
  defdelegate record_digest(record), to: Record, as: :digest

  # OP-63
  @doc "Computes the Merkle leaf hash of an audit record at `pos` in the log `origin`; see `Relay.Audit.Record`."
  @spec leaf_hash(String.t(), non_neg_integer(), Record.leaf()) :: hash()
  defdelegate leaf_hash(origin, pos, leaf), to: Record

  @doc "Returns the root of the empty Merkle tree."
  @spec empty_root() :: hash()
  defdelegate empty_root(), to: Merkle

  @doc "Appends a leaf hash to the frontier of a tree of `size` leaves; see `Relay.Audit.Merkle`."
  @spec frontier_append([hash()], non_neg_integer(), hash()) :: [hash()]
  defdelegate frontier_append(frontier, size, leaf), to: Merkle

  @doc "Computes the root of a tree from its frontier."
  @spec frontier_root([hash()]) :: hash()
  defdelegate frontier_root(frontier), to: Merkle

  @doc "Returns true if `frontier` has the shape of a tree of `size` leaves."
  @spec frontier_valid?(term(), term()) :: boolean()
  defdelegate frontier_valid?(frontier, size), to: Merkle

  @doc "Verifies the inclusion proof of one audit record's leaf against a checkpoint root."
  @spec verify_inclusion(non_neg_integer(), pos_integer(), hash(), [hash()], hash()) :: boolean()
  defdelegate verify_inclusion(index, size, leaf_hash, proof, root), to: Merkle

  @doc "Formats the body of a C2SP checkpoint."
  @spec checkpoint_text(String.t(), non_neg_integer(), hash()) :: String.t()
  defdelegate checkpoint_text(origin, tree_size, root_hash), to: Note

  @doc "Signs note text as a C2SP signed note; see `Relay.Audit.Note.sign/4`."
  @spec sign_note(
          String.t(),
          String.t(),
          Note.public_key(),
          (binary() -> {:ok, binary()} | {:error, Relay.Error.t()})
        ) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  defdelegate sign_note(text, name, public_key, sign_fun), to: Note, as: :sign

  @doc "Encodes the verifier key of the checkpoint signing key for a log origin."
  @spec verifier_key(String.t(), Note.public_key()) :: String.t()
  defdelegate verifier_key(origin, public_key), to: Note

  @doc "Opens a signed checkpoint with verifier keys and returns its parsed body."
  @spec open_checkpoint(String.t(), [String.t()]) ::
          {:ok, Note.checkpoint()} | {:error, Relay.Error.t()}
  def open_checkpoint(note, verifier_keys) when is_binary(note) and is_list(verifier_keys) do
    with {:ok, verifiers} <- parse_keys(verifier_keys),
         {:ok, text, _names} <- Note.open(note, verifiers),
         do: Note.parse_checkpoint(text)
  end

  defp parse_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Note.parse_verifier_key(key) do
        {:ok, verifier} -> {:cont, {:ok, [verifier | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
