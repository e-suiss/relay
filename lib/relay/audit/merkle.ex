defmodule Relay.Audit.Merkle do
  @moduledoc """
  RFC 6962 / RFC 9162 Merkle tree hashing with SHA-256: leaves are hashed with the `0x00` prefix, interior nodes with `0x01`. Besides the full-tree functions, a frontier (the hashes of the perfect subtrees along the right edge, largest first) lets the checkpoint job append leaves and compute the root in logarithmic space without reading earlier leaves.
  """

  @type hash :: <<_::256>>
  @type frontier :: [hash()]

  # OP-63
  # TN-46
  @doc "Hashes a leaf: `SHA-256(0x00 ‖ data)`."
  @spec leaf_hash(iodata()) :: hash()
  def leaf_hash(data), do: :crypto.hash(:sha256, [<<0>>, data])

  @doc "Hashes an interior node: `SHA-256(0x01 ‖ left ‖ right)`."
  @spec node_hash(hash(), hash()) :: hash()
  def node_hash(<<_::256>> = left, <<_::256>> = right),
    do: :crypto.hash(:sha256, [<<1>>, left, right])

  @doc "Returns the root of the empty tree, `SHA-256()` of no bytes."
  @spec empty_root() :: hash()
  def empty_root, do: :crypto.hash(:sha256, "")

  @doc "Computes the Merkle tree hash of a list of leaf hashes."
  @spec root([hash()]) :: hash()
  def root([]), do: empty_root()
  def root([leaf]), do: leaf

  def root(leaves) do
    {left, right} = Enum.split(leaves, split_point(length(leaves)))
    node_hash(root(left), root(right))
  end

  @doc "Returns the audit path of the leaf at `index` in a tree of `leaves`, nearest sibling first."
  @spec inclusion_proof(non_neg_integer(), [hash()]) :: {:ok, [hash()]} | :error
  def inclusion_proof(index, leaves)
      when is_integer(index) and index >= 0 and index < length(leaves),
      do: {:ok, path(index, leaves)}

  def inclusion_proof(_index, _leaves), do: :error

  defp path(_index, [_leaf]), do: []

  defp path(index, leaves) do
    k = split_point(length(leaves))
    {left, right} = Enum.split(leaves, k)

    if index < k,
      do: path(index, left) ++ [root(right)],
      else: path(index - k, right) ++ [root(left)]
  end

  @doc "Verifies an audit path (RFC 9162 §2.1.3.2) for the leaf at `index` in a tree of `size` leaves."
  @spec verify_inclusion(non_neg_integer(), pos_integer(), hash(), [hash()], hash()) :: boolean()
  def verify_inclusion(index, size, <<_::256>> = leaf, proof, <<_::256>> = root)
      when is_integer(index) and is_integer(size) and index >= 0 and index < size and
             is_list(proof) do
    case climb(index, size - 1, leaf, proof) do
      {:ok, computed} -> Relay.Crypto.secure_compare(computed, root)
      :error -> false
    end
  end

  def verify_inclusion(_index, _size, _leaf, _proof, _root), do: false

  defp climb(_fn, 0, hash, []), do: {:ok, hash}
  defp climb(_fn, _sn, _hash, []), do: :error

  defp climb(fn_index, sn, hash, [<<_::256>> = sibling | rest]) do
    cond do
      sn == 0 ->
        :error

      Bitwise.band(fn_index, 1) == 1 or fn_index == sn ->
        {fn_index, sn} = shift_while_even(fn_index, sn)
        climb(Bitwise.bsr(fn_index, 1), Bitwise.bsr(sn, 1), node_hash(sibling, hash), rest)

      true ->
        climb(Bitwise.bsr(fn_index, 1), Bitwise.bsr(sn, 1), node_hash(hash, sibling), rest)
    end
  end

  defp climb(_fn, _sn, _hash, _proof), do: :error

  defp shift_while_even(fn_index, sn) do
    if Bitwise.band(fn_index, 1) == 0 and fn_index != 0,
      do: shift_while_even(Bitwise.bsr(fn_index, 1), Bitwise.bsr(sn, 1)),
      else: {fn_index, sn}
  end

  @doc "Appends a leaf hash to a frontier of a tree of `size` leaves."
  @spec frontier_append(frontier(), non_neg_integer(), hash()) :: frontier()
  def frontier_append(frontier, size, <<_::256>> = leaf)
      when is_list(frontier) and is_integer(size) and size >= 0 do
    merge(Enum.reverse(frontier), size, leaf) |> Enum.reverse()
  end

  defp merge([left | rest], size, hash) when Bitwise.band(size, 1) == 1,
    do: merge(rest, Bitwise.bsr(size, 1), node_hash(left, hash))

  defp merge(reversed, _size, hash), do: [hash | reversed]

  @doc "Computes the root of a tree from its frontier."
  @spec frontier_root(frontier()) :: hash()
  def frontier_root([]), do: empty_root()

  def frontier_root(frontier) do
    [last | rest] = Enum.reverse(frontier)
    Enum.reduce(rest, last, fn left, acc -> node_hash(left, acc) end)
  end

  @doc "Builds the frontier of a tree from its leaf hashes, in order."
  @spec frontier([hash()]) :: frontier()
  def frontier(leaves) when is_list(leaves) do
    {frontier, _size} =
      Enum.reduce(leaves, {[], 0}, fn leaf, {frontier, size} ->
        {frontier_append(frontier, size, leaf), size + 1}
      end)

    frontier
  end

  @doc "Returns true if `frontier` has the shape of a tree of `size` leaves: one hash per set bit."
  @spec frontier_valid?(term(), term()) :: boolean()
  def frontier_valid?(frontier, size) when is_list(frontier) and is_integer(size) and size >= 0,
    do:
      length(frontier) == popcount(size, 0) and
        Enum.all?(frontier, &match?(<<_::256>>, &1))

  def frontier_valid?(_frontier, _size), do: false

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(Bitwise.bsr(n, 1), acc + Bitwise.band(n, 1))

  defp split_point(n), do: split_point(n, 1)
  defp split_point(n, k) when k * 2 < n, do: split_point(n, k * 2)
  defp split_point(_n, k), do: k
end
