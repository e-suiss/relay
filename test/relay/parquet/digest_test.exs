defmodule Relay.Parquet.DigestTest do
  use ExUnit.Case, async: true

  alias Relay.Parquet.Digest
  alias Relay.Parquet.Port
  alias Relay.Platform.Maintenance.ArchiveStore

  @rows [["1", "alpha"], ["2", nil], ["3", ""]]
  @vector "8320119bf45f4d4e744ca70365f776d3305899a6af1dff66d2905938bb32ef60"

  describe "OP-84 canonical row digest" do
    test "OP-84: the digest of the shared vector matches the archive program's" do
      assert Base.encode16(Digest.of(@rows), case: :lower) == @vector
    end

    test "OP-84: the digest of no rows is the SHA-256 of nothing" do
      assert Digest.of([]) == :crypto.hash(:sha256, "")
    end

    test "OP-84: rows decode from their canonical encoding" do
      binary = @rows |> Enum.map(&Digest.encode_row/1) |> IO.iodata_to_binary()
      assert Port.decode_rows(binary, 3, 2) == {:ok, @rows}
      assert {:error, %Relay.Error{}} = Port.decode_rows(binary, 2, 2)
      assert {:error, %Relay.Error{}} = Port.decode_rows(binary <> <<0>>, 3, 2)
    end

    test "OP-84: a row becomes one line of the COPY text format" do
      line = ArchiveStore.copy_line(["a\tb", nil, "c\\d\ne\r"])
      assert IO.iodata_to_binary(line) == "a\\tb\t\\N\tc\\\\d\\ne\\r\n"
    end

    test "OP-84: column names are quoted as identifiers" do
      assert ArchiveStore.quote_ident(~s(a"b)) == ~s("a""b")
    end
  end
end
