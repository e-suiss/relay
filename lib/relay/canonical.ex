defmodule Relay.Canonical do
  @moduledoc """
  Canonical serialization for structures that are signed, hashed or bound as authenticated data: deterministically encoded CBOR (RFC 8949 §4.2.1 core deterministic encoding requirements). Supported values are integers in the 64-bit CBOR range, UTF-8 text (`String.t()`), byte strings (`{:bytes, binary}`), lists, maps, `true`, `false` and `nil`. Floats, atoms and invalid UTF-8 text are refused, so the same value always has exactly one encoding.
  """

  @type value ::
          integer()
          | String.t()
          | {:bytes, binary()}
          | boolean()
          | nil
          | [value()]
          | %{optional(value()) => value()}

  @max_uint Integer.pow(2, 64) - 1
  @min_nint -Integer.pow(2, 64)

  # TN-35
  @doc "Encodes a value canonically."
  @spec encode(term()) :: {:ok, binary()} | {:error, Relay.Error.t()}
  def encode(value) do
    case do_encode(value) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      :error -> {:error, Relay.Error.new(:not_canonical, "value has no canonical encoding")}
    end
  end

  @doc "Encodes a value canonically and raises if it has no canonical encoding."
  @spec encode!(value()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, binary} -> binary
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp do_encode(n) when is_integer(n) and n >= 0 and n <= @max_uint, do: {:ok, head(0, n)}
  defp do_encode(n) when is_integer(n) and n < 0 and n >= @min_nint, do: {:ok, head(1, -1 - n)}
  defp do_encode(false), do: {:ok, <<0xF4>>}
  defp do_encode(true), do: {:ok, <<0xF5>>}
  defp do_encode(nil), do: {:ok, <<0xF6>>}

  defp do_encode({:bytes, bytes}) when is_binary(bytes),
    do: {:ok, [head(2, byte_size(bytes)), bytes]}

  defp do_encode(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, [head(3, byte_size(text)), text]}, else: :error
  end

  defp do_encode(list) when is_list(list) do
    with {:ok, items} <- encode_all(list, []),
         do: {:ok, [head(4, length(list)) | items]}
  end

  defp do_encode(map) when is_map(map) and not is_struct(map) do
    with {:ok, pairs} <- encode_pairs(Map.to_list(map), []) do
      sorted = Enum.sort_by(pairs, fn {key, _value} -> key end)
      {:ok, [head(5, map_size(map)) | Enum.map(sorted, fn {key, value} -> [key, value] end)]}
    end
  end

  defp do_encode(_other), do: :error

  defp encode_all([], acc), do: {:ok, Enum.reverse(acc)}

  defp encode_all([item | rest], acc) do
    with {:ok, encoded} <- do_encode(item), do: encode_all(rest, [encoded | acc])
  end

  defp encode_pairs([], acc), do: {:ok, acc}

  defp encode_pairs([{key, value} | rest], acc) do
    with {:ok, key} <- do_encode(key),
         {:ok, value} <- do_encode(value) do
      encode_pairs(rest, [{IO.iodata_to_binary(key), value} | acc])
    end
  end

  defp head(major, n) when n < 24, do: <<major::3, n::5>>
  defp head(major, n) when n < 0x100, do: <<major::3, 24::5, n::8>>
  defp head(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
  defp head(major, n) when n < 0x100000000, do: <<major::3, 26::5, n::32>>
  defp head(major, n), do: <<major::3, 27::5, n::64>>
end
