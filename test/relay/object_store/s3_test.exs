defmodule Relay.ObjectStore.S3Test do
  use ExUnit.Case, async: true

  alias Relay.ObjectStore.S3
  alias RelayDev.ObjectStore

  describe "OP-84 object lock periods" do
    test "OP-84: an object stays locked until the later of the bucket default and the retention period" do
      now = ~U[2026-11-18 10:20:30.123456Z]

      assert S3.retain_until({:days, 1}, now, 3653) == ~U[2036-11-18 10:20:30Z]
      assert S3.retain_until({:years, 11}, now, 3653) == ~U[2037-11-18 10:20:30Z]
      assert S3.retain_until({:days, 30}, now, 0) == ~U[2026-12-18 10:20:30Z]
    end

    test "OP-84: the archive store options are validated" do
      good = ObjectStore.local(bucket: "relay-archive")
      assert S3.validate(good) == :ok
      assert {:error, _} = S3.validate(Keyword.delete(good, :bucket))
      assert {:error, _} = S3.validate(Keyword.put(good, :prefix, "x"))
      assert {:error, _} = S3.validate(Keyword.put(good, :endpoint, "s3.example.com"))
      assert {:error, _} = S3.validate(Keyword.put(good, :extra, 1))
    end
  end

  describe "OP-84 large objects" do
    @describetag :integration
    @describetag :tmp_dir

    setup do
      {:ok, _} = Application.ensure_all_started(:req)
      store = ObjectStore.local(bucket: "relay-archive")
      :ok = ObjectStore.setup(store)
      %{store: store}
    end

    test "OP-84: a file above the part size goes up in parts, locked, and reads back unchanged",
         %{store: store, tmp_dir: dir} do
      path = Path.join(dir, "big.bin")
      File.write!(path, :crypto.strong_rand_bytes(17 * 1024 * 1024 + 5))
      key = "test/" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      until = DateTime.add(DateTime.utc_now(), 2, :day)

      assert :ok = S3.put_file(store, key, path, until)
      assert {:ok, {"GOVERNANCE", _}} = ObjectStore.retention(store, key)

      back = Path.join(dir, "back.bin")
      assert :ok = S3.get_file(store, key, back)
      assert File.read!(back) == File.read!(path)

      assert {:error, %Relay.Error{code: :publication_missing}} =
               S3.get_file(store, key <> "-missing", Path.join(dir, "missing.bin"))
    end

    test "OP-84: a bucket without object lock is refused", %{tmp_dir: dir} do
      store = ObjectStore.local(bucket: "relay-archive-unlocked")
      :ok = ObjectStore.setup_unlocked(store)
      path = Path.join(dir, "small.bin")
      File.write!(path, "x")

      assert {:error, %Relay.Error{code: :target_unlocked}} =
               S3.put_file(store, "test/small", path, DateTime.utc_now())
    end
  end
end
