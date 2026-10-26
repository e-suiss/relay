defmodule Relay.BinaryTest do
  use ExUnit.Case, async: true

  describe "T-45 refc binary playbook" do
    test "T-45: a part of a large binary is detached from its parent" do
      body = :binary.copy(<<"x">>, 100_000) <> :binary.copy(<<"z">>, 200)
      part = :binary.part(body, 100_000, 200)

      assert :binary.referenced_byte_size(part) > byte_size(part)
      kept = Relay.Binary.keep(part)
      assert kept == :binary.copy(<<"z">>, 200)
      assert :binary.referenced_byte_size(kept) == byte_size(kept)
    end

    test "T-45: a binary that owns its bytes is returned unchanged" do
      body = :binary.copy(<<"y">>, 100_000)
      assert :binary.referenced_byte_size(Relay.Binary.keep(body)) == 100_000
    end
  end
end
