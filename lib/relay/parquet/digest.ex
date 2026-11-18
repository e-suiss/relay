defmodule Relay.Parquet.Digest do
  @moduledoc """
  The canonical row encoding of archived rows and its SHA-256 digest. A row is encoded value by value: `0` for `nil`, or `1`, a four-byte big-endian length and the bytes; the digest of a file is the SHA-256 of the encodings of its rows in order. The `archive_port` program frames rows the same way and computes the same digest.
  """

  @type t :: :crypto.hash_state()

  # OP-84
  @doc "The canonical encoding of one row."
  @spec encode_row([binary() | nil]) :: iodata()
  def encode_row(row) when is_list(row), do: Enum.map(row, &encode_value/1)

  defp encode_value(nil), do: <<0>>
  defp encode_value(value) when is_binary(value), do: [<<1, byte_size(value)::32>>, value]

  @doc "Starts a digest."
  @spec new() :: t()
  def new, do: :crypto.hash_init(:sha256)

  @doc "Adds one row to a digest."
  @spec update(t(), [binary() | nil]) :: t()
  def update(state, row), do: :crypto.hash_update(state, encode_row(row))

  @doc "Returns the 32-byte digest."
  @spec final(t()) :: <<_::256>>
  def final(state), do: :crypto.hash_final(state)

  @doc "The digest of a list of rows."
  @spec of([[binary() | nil]]) :: <<_::256>>
  def of(rows) when is_list(rows), do: rows |> Enum.reduce(new(), &update(&2, &1)) |> final()
end
