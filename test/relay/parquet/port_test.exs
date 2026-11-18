defmodule Relay.Parquet.PortTest do
  use ExUnit.Case, async: true

  alias Relay.Parquet.Digest

  @moduletag :integration
  @moduletag :tmp_dir

  @executable Path.expand("../../../native/archive_port/target/release/archive_port", __DIR__)

  setup_all do
    assert File.exists?(@executable), "build the port program first: native/build.sh"
    sha256 = (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()
    %{opts: [executable: @executable, sha256: sha256]}
  end

  defp rows(count),
    do: for(i <- 1..count, do: [Integer.to_string(i), if(rem(i, 3) == 0, do: nil, else: "v#{i}")])

  describe "OP-84 Parquet through the archive program" do
    test "OP-84: rows written in batches read back with the same count, digest and order",
         %{opts: opts, tmp_dir: dir} do
      path = Path.join(dir, "rows.parquet")
      rows = rows(2_500)

      assert {:ok, %{rows: 2_500, digest: digest, bytes: bytes}} =
               Relay.Parquet.write(path, ["id", "value"], Stream.map(rows, & &1), opts)

      assert digest == Digest.of(rows)
      assert bytes == File.stat!(path).size

      assert {:ok, %{rows: 2_500, digest: ^digest, columns: ["id", "value"]}} =
               Relay.Parquet.verify(path, opts)

      assert {:ok, ["id", "value"], read} =
               Relay.Parquet.reduce(path, [], &(&2 ++ &1), opts)

      assert read == rows
    end

    test "OP-84: an empty table round-trips", %{opts: opts, tmp_dir: dir} do
      path = Path.join(dir, "empty.parquet")
      assert {:ok, %{rows: 0}} = Relay.Parquet.write(path, ["id"], [], opts)
      assert {:ok, ["id"], []} = Relay.Parquet.reduce(path, [], &(&2 ++ &1), opts)
    end

    test "OP-84: bad rows, existing files and invalid UTF-8 are refused",
         %{opts: opts, tmp_dir: dir} do
      path = Path.join(dir, "bad.parquet")

      assert {:error, %Relay.Error{code: :parquet_bad_row}} =
               Relay.Parquet.write(path, ["id", "value"], [["1"]], opts)

      assert {:error, %Relay.Error{code: :parquet_io}} =
               Relay.Parquet.write(path, ["id"], [["1"]], opts)

      other = Path.join(dir, "utf8.parquet")

      assert {:error, %Relay.Error{code: :parquet_encoding}} =
               Relay.Parquet.write(other, ["id"], [[<<0xFF>>]], opts)

      assert {:error, %Relay.Error{code: :parquet_io}} =
               Relay.Parquet.verify(Path.join(dir, "missing.parquet"), opts)
    end

    test "T-53: a program that does not match its checksum is not started",
         %{opts: opts, tmp_dir: dir} do
      opts = Keyword.put(opts, :sha256, String.duplicate("0", 64))

      assert {:error, %Relay.Error{code: :parquet_integrity}} =
               Relay.Parquet.write(Path.join(dir, "x.parquet"), ["id"], [], opts)
    end
  end
end
