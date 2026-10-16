defmodule Relay.Keys.ProtocolTest do
  use ExUnit.Case, async: true

  alias Relay.Keys.Protocol
  alias Relay.Redacted

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  describe "TN-63 request encoding" do
    test "TN-63: ping" do
      assert bin(Protocol.encode(7, :ping)) == <<1, 0, 0, 0, 7, 0>>
    end

    test "TN-28: sign carries the algorithm, the label and the message" do
      assert bin(Protocol.encode(9, {:sign, :es256, "apns", "hc"})) ==
               <<1, 0, 0, 0, 9, 1, 1, 0, 0, 0, 4, "apns", 0, 0, 0, 2, "hc">>

      assert <<1, _::32, 1, 2, _::binary>> = bin(Protocol.encode(1, {:sign, :rs256, "f", ""}))
      assert <<1, _::32, 1, 3, _::binary>> = bin(Protocol.encode(1, {:sign, :ed25519, "c", ""}))
    end

    test "TN-31: public key export" do
      assert bin(Protocol.encode(3, {:public_key, :ed25519, "c"})) ==
               <<1, 0, 0, 0, 3, 2, 3, 0, 0, 0, 1, "c">>
    end

    test "TN-27: wrap and unwrap" do
      assert bin(Protocol.encode(1, {:wrap, "k", "a", <<5>>})) ==
               <<1, 0, 0, 0, 1, 3, 0, 0, 0, 1, "k", 0, 0, 0, 1, "a", 0, 0, 0, 1, 5>>

      assert <<1, 0, 0, 0, 2, 4, _::binary>> = bin(Protocol.encode(2, {:unwrap, "k", "a", "w"}))
    end
  end

  describe "TN-63 response decoding" do
    test "TN-63: fields are split by their length prefix" do
      assert Protocol.decode(<<1, 0, 0, 0, 5, 0, 0, 0, 0, 2, "ab", 0, 0, 0, 0>>) ==
               {:ok, 5, 0, ["ab", ""]}
    end

    test "TN-63: malformed frames are a protocol error" do
      for frame <- [<<>>, <<2, 0, 0, 0, 1, 0>>, <<1, 0, 0, 0, 1, 0, 0, 0, 0, 9, "a">>] do
        assert {:error, %Relay.Error{code: :key_store_protocol}} = Protocol.decode(frame)
      end
    end

    test "TN-63: results follow the request kind" do
      assert Protocol.result(:ping, 0, []) == :ok
      assert Protocol.result({:sign, :es256}, 0, ["sig"]) == {:ok, "sig"}
      assert Protocol.result({:public_key, :rs256}, 0, ["n", "e"]) == {:ok, {"n", "e"}}
      assert Protocol.result({:public_key, :es256}, 0, ["point"]) == {:ok, "point"}
      assert Protocol.result(:wrap, 0, ["w"]) == {:ok, "w"}

      assert {:error, %Relay.Error{code: :key_store_protocol}} =
               Protocol.result({:sign, :es256}, 0, [])
    end

    test "TN-26: unwrapped key material comes back redacted" do
      assert {:ok, key} = Protocol.result(:unwrap, 0, ["secret-key-bytes"])
      refute inspect(key) =~ "secret-key-bytes"
      assert Redacted.expose(key) == "secret-key-bytes"
    end

    test "TN-63: status codes map to typed errors" do
      codes = %{
        1 => :key_store_bad_request,
        2 => :key_store_version,
        3 => :key_not_found,
        4 => :key_integrity,
        5 => :key_store_token,
        6 => :key_store_internal
      }

      for {status, code} <- codes do
        assert {:error, %Relay.Error{code: ^code, message: "key store: m"}} =
                 Protocol.result(:wrap, status, ["m"])
      end

      assert {:error, %Relay.Error{code: :key_store_protocol}} = Protocol.result(:wrap, 7, ["m"])
    end
  end
end
