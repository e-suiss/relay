defmodule Relay.Webhooks.Destination.KafkaScramTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Destination.Kafka.Scram

  @nonce "rOprNGfwEbeRWgbNEkqO"
  @combined "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
  @salt "W22ZaJ0SNY7soEsUEjb6gQ=="
  @server_first "r=" <> @combined <> ",s=" <> @salt <> ",i=4096"
  @proof_256 "dHzbZapWIk4jUhN+Ute9" <> "ytag9zjfMHgsqmmiz7AndVQ="
  @server_256 "6rriTRBi23WpRR/wtup+" <> "mMhUZUn/dB5nLTJRsjl95G4="
  @proof_512_head "gMGXRcevScNtxZ6/8lQYpGtnsNAc3mGcmNomv+xnoOMw"
  @proof_512 @proof_512_head <> "+3R2xNJdMNnzMlTN8PPC6wdp6dybEmDYXYTxwnYPJQ=="
  @server_512_head "ZQnYEgWQMFmmsM8aQMF0nDDCy/AgCzkwk8CmMZYcMg0v"
  @server_512 @server_512_head <> "SVlKDanekLtifDSeVGT4+5ZxXnJq199RVG2rR7N7Zw=="

  describe "WH-17 SCRAM" do
    test "WH-17: the first message carries the escaped user name and the nonce" do
      assert Scram.client_first("user", @nonce) ==
               {"n,,n=user,r=" <> @nonce, "n=user,r=" <> @nonce}

      assert {"n,,n=a=3Db=2Cc,r=x", "n=a=3Db=2Cc,r=x"} = Scram.client_first("a=b,c", "x")
    end

    test "WH-17: SCRAM-SHA-256 gives the proof and the server signature of RFC 7677" do
      {_first, bare} = Scram.client_first("user", @nonce)

      assert {:ok, final, signature} =
               Scram.client_final(:sha256, "pencil", bare, @server_first, @nonce, 4096)

      assert final == "c=biws,r=" <> @combined <> ",p=" <> @proof_256
      assert signature == Base.decode64!(@server_256)
      assert :ok = Scram.verify("v=" <> @server_256, signature)
    end

    test "WH-17: SCRAM-SHA-512 gives the proof and the server signature of the same exchange" do
      {_first, bare} = Scram.client_first("user", @nonce)

      assert {:ok, final, signature} =
               Scram.client_final(:sha512, "pencil", bare, @server_first, @nonce, 4096)

      assert final == "c=biws,r=" <> @combined <> ",p=" <> @proof_512
      assert signature == Base.decode64!(@server_512)
      assert :ok = Scram.verify("v=" <> @server_512, signature)
    end

    test "WH-17: a server signature that does not match is refused" do
      signature = Base.decode64!(@server_256)
      other = Base.encode64(:crypto.hash(:sha256, "x"))

      assert :error = Scram.verify("v=" <> other, signature)
      assert :error = Scram.verify("v=" <> Base.encode64("short"), signature)
      assert :error = Scram.verify("v=not base64", signature)
      assert :error = Scram.verify("e=invalid-proof", signature)
    end

    test "WH-17: a server message that does not continue the exchange is refused" do
      {_first, bare} = Scram.client_first("user", @nonce)
      final = &Scram.client_final(:sha256, "pencil", bare, &1, @nonce, &2)

      assert :error = final.("r=another" <> @combined <> ",s=" <> @salt <> ",i=4096", 4096)
      assert :error = final.("r=" <> @nonce <> ",s=" <> @salt <> ",i=4096", 4096)
      assert :error = final.("r=" <> @combined <> ",s=not base64,i=4096", 4096)
      assert :error = final.("r=" <> @combined <> ",s=" <> @salt <> ",i=0", 4096)
      assert :error = final.("r=" <> @combined <> ",s=" <> @salt, 4096)
      assert :error = final.("e=other-error", 4096)
    end

    test "WH-17: an iteration count above the caller's bound is refused" do
      {_first, bare} = Scram.client_first("user", @nonce)

      assert :error = Scram.client_final(:sha256, "pencil", bare, @server_first, @nonce, 4095)
    end
  end
end
