defmodule Relay.Audit.CheckpointTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Audit.Checkpointer.State
  alias Relay.Audit.Merkle
  alias Relay.Audit.Note
  alias Relay.Audit.Record

  @vectors "test/vectors/c2sp/vectors.json" |> File.read!() |> Jason.decode!()

  defp hash(n), do: :crypto.hash(:sha256, <<n::64>>)

  defp leaves do
    gen all(n <- integer(0..70)) do
      Enum.map(1..n//1, &Merkle.leaf_hash(<<&1::32>>))
    end
  end

  describe "OP-63 RFC 6962 Merkle tree" do
    test "OP-63: the empty tree hashes to SHA-256 of nothing and a leaf takes the 0x00 prefix" do
      assert Merkle.empty_root() ==
               Base.decode16!("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")

      [%{"text" => text}] = Enum.filter(@vectors["checkpoints"], &Map.has_key?(&1, "text"))
      {:ok, body} = Note.parse_checkpoint(text)
      assert body.root_hash == Merkle.leaf_hash("hello world")
    end

    test "OP-63: interior nodes split at the largest power of two below the size" do
      [a, b, c] = Enum.map(1..3, &hash/1)
      assert Merkle.root([a, b, c]) == Merkle.node_hash(Merkle.node_hash(a, b), c)
      assert Merkle.root([a, b]) == Merkle.node_hash(a, b)
      assert Merkle.root([a]) == a
    end

    property "OP-63: the appended frontier yields the same root as the full tree" do
      check all(leaves <- leaves()) do
        frontier = Merkle.frontier(leaves)
        assert Merkle.frontier_valid?(frontier, length(leaves))
        assert Merkle.frontier_root(frontier) == Merkle.root(leaves)
      end
    end

    property "OP-63: every leaf has an inclusion proof that verifies, and only for that leaf" do
      check all(leaves <- leaves(), leaves != [], index <- integer(0..(length(leaves) - 1))) do
        root = Merkle.root(leaves)
        size = length(leaves)
        leaf = Enum.at(leaves, index)
        assert {:ok, proof} = Merkle.inclusion_proof(index, leaves)
        assert Merkle.verify_inclusion(index, size, leaf, proof, root)
        refute Merkle.verify_inclusion(index, size, hash(-1), proof, root)
        refute Merkle.verify_inclusion(index, size, leaf, proof, hash(-2))

        if size > 1 do
          other = rem(index + 1, size)
          refute Merkle.verify_inclusion(other, size, leaf, proof, root)
        end
      end
    end
  end

  describe "OP-63 C2SP signed-note and tlog-checkpoint vectors" do
    test "OP-63: published signed notes open with their verifier keys" do
      for vector <- @vectors["signed_notes"] do
        assert {:ok, verifier} = Note.parse_verifier_key(vector["verifier_key"])
        assert Note.verifier_key(verifier.name, verifier.public_key) == vector["verifier_key"]
        assert {:ok, text, [name]} = Note.open(vector["note"], [verifier])
        assert text == vector["text"]
        assert name == verifier.name
      end
    end

    test "OP-63: signing the Go vector text with its private key reproduces the published note" do
      [vector] = Enum.filter(@vectors["signed_notes"], &Map.has_key?(&1, "private_key"))

      ["PRIVATE", "KEY", name, _hash, encoded] =
        String.split(vector["private_key"], "+", parts: 5)

      <<1, seed::binary-32>> = Base.decode64!(encoded)
      {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
      sign = fn text -> {:ok, :crypto.sign(:eddsa, :none, text, [seed, :ed25519])} end
      assert Note.sign(vector["text"], name, public, sign) == {:ok, vector["note"]}
    end

    test "OP-63: a changed text, a changed signature or an unknown key does not verify" do
      [vector | _] = @vectors["signed_notes"]
      {:ok, verifier} = Note.parse_verifier_key(vector["verifier_key"])
      tampered = String.replace(vector["note"], "example", "exemple", global: false)
      assert {:error, %{code: :invalid_signature}} = Note.open(tampered, [verifier])
      assert {:error, %{code: :unverified_note}} = Note.open(vector["note"], [])
      assert {:error, %{code: :malformed_note}} = Note.open(vector["text"], [verifier])
    end

    test "OP-63: checkpoint bodies parse into origin, size and root and format back" do
      for vector <- @vectors["checkpoints"] do
        text =
          vector["text"] || vector["note"] |> String.split("\n\n") |> hd() |> Kernel.<>("\n")

        assert {:ok, body} = Note.parse_checkpoint(text)
        assert body.origin == vector["origin"]
        assert body.tree_size == vector["tree_size"]
        assert Note.checkpoint_text(body.origin, body.tree_size, body.root_hash) == text

        if vector["root_hash"],
          do: assert(Base.encode64(body.root_hash) == vector["root_hash"])
      end
    end

    test "OP-63: malformed checkpoint bodies are refused" do
      root = Base.encode64(hash(1))

      for bad <- [
            "o\n01\n#{root}\n",
            "o\n-1\n#{root}\n",
            "o\n1\n#{root}",
            "o\n1\nAAAA\n",
            "\n1\n#{root}\n",
            "o\n1\n"
          ] do
        assert {:error, %{code: :invalid_checkpoint}} = Note.parse_checkpoint(bad)
      end
    end

    test "OP-63: key names with spaces or plus signs are refused" do
      refute Note.valid_key_name?("a b")
      refute Note.valid_key_name?("a+b")
      refute Note.valid_key_name?("")
      assert Note.valid_key_name?("relay.example/relay/audit/2026")
    end
  end

  describe "TN-46 checkpoint job state" do
    test "TN-46: the origin is per installation host and UTC year" do
      assert State.origin("relay.example.com", 2026) == "relay.example.com/relay/audit/2026"
      state = State.append(State.new("a/relay/audit/2026", "42"), [hash(1)])
      rotated = State.rotate(state, "a/relay/audit/2027")
      assert rotated.tree_size == 0 and rotated.watermark == "42"
      assert State.rotate(state, state.origin) == state
    end

    test "TN-46: a grown tree is signed at once, an unchanged one after a quiet minute" do
      state = State.new("o")
      assert State.decide(state, 0) == :checkpoint
      state = State.signed(state, 0)
      assert State.decide(state, 59_999) == :idle
      assert State.decide(state, State.heartbeat_ms()) == :heartbeat
      grown = State.append(state, [hash(1)])
      assert State.decide(grown, 1) == :checkpoint
      assert State.interval_ms() == 1_000
    end

    test "TN-46: a row integrated more than a second after it was written is overdue" do
      at = ~U[2026-10-16 12:00:00.000000Z]
      refute State.overdue?(at, ~U[2026-10-16 12:00:01.000000Z])
      assert State.overdue?(at, ~U[2026-10-16 12:00:01.001000Z])
    end

    test "TN-46: a full page is cut before its last transaction so no transaction is split" do
      row = fn txid, n ->
        %{txid: txid, created_at: DateTime.from_unix!(n), audit_id: <<n::128>>}
      end

      short = [row.(5, 1), row.(3, 2)]
      assert {:ok, [%{txid: 3}, %{txid: 5}], 9} = State.select(short, 3, 9)

      full = [row.(3, 1), row.(4, 2), row.(4, 3)]
      assert {:ok, [%{txid: 3}], 4} = State.select(full, 3, 9)
      assert State.select([row.(4, 1), row.(4, 2)], 2, 9) == :grow
    end

    property "TN-46: the saved state round-trips and a corrupted frontier is refused" do
      check all(leaves <- leaves(), watermark <- integer(0..1_000_000)) do
        state = State.append(State.new("o", Integer.to_string(watermark)), leaves)
        json = state |> State.to_json() |> Jason.encode!() |> Jason.decode!()
        assert {:ok, restored} = State.from_json(json)
        assert State.root(restored) == State.root(state)
        assert restored.tree_size == length(leaves)
        assert State.from_json(%{json | "tree_size" => length(leaves) * 2 + 1}) == :error
      end
    end
  end

  describe "TN-46 record commitments" do
    @leaf %{
      tenant_id: <<1::128>>,
      environment: "live",
      audit_id: <<2::128>>,
      created_at: ~U[2026-10-16 12:00:00.123456Z],
      record_digest: <<3::256>>
    }

    test "TN-46: the leaf binds origin, position and the record" do
      leaf = Record.leaf_hash("o", 0, @leaf)
      assert leaf == Merkle.leaf_hash(Record.envelope("o", 0, @leaf))
      refute leaf == Record.leaf_hash("o", 1, @leaf)
      refute leaf == Record.leaf_hash("p", 0, @leaf)
      refute leaf == Record.leaf_hash("o", 0, %{@leaf | record_digest: <<4::256>>})
      refute leaf == Record.leaf_hash("o", 0, %{@leaf | environment: "test"})
    end

    test "TN-46: the leaf envelope encoding is stable" do
      assert Base.encode16(Record.leaf_hash("o", 0, @leaf), case: :lower) ==
               "6e83de45919f24b7d44d00496fc0a2c2adfa53d1159e07372be6ac952731bbd8"
    end

    test "TN-46: the record digest covers actor, target and details" do
      record = %{
        tenant_id: <<1::128>>,
        environment: "live",
        action: "subject.erased",
        actor_kind: "system",
        actor_ref: "relay",
        on_behalf_of_ref: "relay"
      }

      digest = Record.digest(record)
      assert byte_size(digest) == 32
      refute digest == Record.digest(%{record | actor_ref: "other"})
      refute digest == Record.digest(Map.put(record, :details, "x"))
      assert digest == Record.digest(Map.put(record, :target_id, nil))
    end
  end
end
