defmodule Relay.Channels.Email.DkimTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Dkim
  alias Relay.Channels.Email.Mime

  @dir Path.expand("../../../fixtures/email/dkim", __DIR__)
  @rfc8463_p "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDkHlOQoBTzWRiGs5V6NpP3idY6Wk08a5qhdR6wy5bdOKb2jLQiY/J16JYi0Qvx/byYzCNb3W91y3FutACDfzwQ/BC/e/8uBsCR+yz1Lxj+PL6lHvqMKrM3rG4hstT5QjvHO9PzoxZyVYLzBfO2EeC3Ip3G+2kryOTIKT+l/K4w3QIDAQAB"
  @added ["feedback-id", "list-unsubscribe", "list-unsubscribe-post"]

  @message """
  From: Shop <offers@sender.example>
  To: reader@example.com
  Subject: Spring   offers
  Date: Tue, 03 Nov 2026 10:00:00 +0000
  Message-ID: <m1@sender.example>
  MIME-Version: 1.0
  Content-Type: text/plain; charset=utf-8
  Feedback-ID: spring2026:offers:tenant1:offers
  List-Unsubscribe: <https://relay.example/u/opaque>, <mailto:u-opaque@sender.example>
  List-Unsubscribe-Post: List-Unsubscribe=One-Click

  Spring  offers   inside.\t

  See you.


  """

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    signer = fn data -> {:ok, :public_key.sign(data, :sha256, private)} end
    %{public: public, signer: signer, modulus: elem(private, 2), exponent: elem(private, 3)}
  end

  defp params(extra \\ %{}) do
    base = %{domain: "sender.example", selector: "mkt2026a", timestamp: 1_793_700_000}
    base |> Map.put(:required, @added) |> Map.merge(extra)
  end

  defp signed(message, signer) do
    {:ok, field} = Dkim.sign(message, params(), signer)
    field <> "\r\n" <> Mime.crlf(message)
  end

  describe "RFC 6376 canonicalization" do
    test "CH-36: the RFC 6376 §3.4.6 example canonicalizes as the RFC gives it" do
      assert Dkim.canonical_header("A: X", :relaxed) == "a:X"
      assert Dkim.canonical_header("B : Y\t\r\n\tZ  ", :relaxed) == "b:Y Z"

      body = " C \r\nD \t E\r\n\r\n\r\n"
      assert Dkim.canonical_body(body, :relaxed) == " C\r\nD E\r\n"
      assert Dkim.canonical_body(body, :simple) == " C \r\nD \t E\r\n"
    end

    test "CH-36: an empty body is empty under relaxed and one CRLF under simple" do
      assert Dkim.canonical_body("", :relaxed) == ""
      assert Dkim.canonical_body("\r\n\r\n", :relaxed) == ""
      assert Dkim.canonical_body("", :simple) == "\r\n"
    end
  end

  describe "RFC 8463 vector" do
    test "CH-36: the body hash of the RFC 8463 message is the one it carries" do
      message = @dir |> Path.join("rfc8463.eml") |> File.read!()
      {_head, body} = message |> Mime.crlf() |> Mime.split()
      assert Dkim.body_hash(body, :relaxed) == "2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8="
    end

    test "CH-36: the RFC 8463 rsa-sha256 signature verifies with its published key" do
      message = @dir |> Path.join("rfc8463.eml") |> File.read!()
      assert Dkim.verify(message, @rfc8463_p) == :ok
    end

    test "CH-36: the RFC 8463 signature fails once a signed field changes" do
      message =
        @dir
        |> Path.join("rfc8463.eml")
        |> File.read!()
        |> String.replace("Subject: Is dinner ready?", "Subject: Is lunch ready?")

      assert Dkim.verify(message, @rfc8463_p) == {:error, :bad_signature}
    end
  end

  describe "CH-36 signing" do
    test "CH-36: a signature is rsa-sha256 with relaxed/relaxed and verifies", ctx do
      assert {:ok, field} = Dkim.sign(@message, params(), ctx.signer)
      assert "DKIM-Signature: " <> _rest = field

      tags = Dkim.tags(field)
      assert tags["v"] == "1"
      assert tags["a"] == "rsa-sha256"
      assert tags["c"] == "relaxed/relaxed"
      assert tags["d"] == "sender.example"
      assert tags["s"] == "mkt2026a"
      assert tags["t"] == "1793700000"
      refute Map.has_key?(tags, "x")

      assert Dkim.verify(field <> "\r\n" <> Mime.crlf(@message), ctx.public) == :ok
      assert field |> String.split("\r\n") |> Enum.all?(&(byte_size(&1) <= 998))
    end

    test "CH-38: the fields Relay adds are inside h= and oversigned", ctx do
      {:ok, field} = Dkim.sign(@message, params(), ctx.signer)
      h = field |> Dkim.tags() |> Map.fetch!("h") |> String.split(":")

      for name <- @added, do: assert(Enum.count(h, &(&1 == name)) == 2, name)
      assert Enum.count(h, &(&1 == "from")) == 2
      assert "subject" in h and "date" in h and "message-id" in h
    end

    test "CH-36: adding an oversigned field after signing breaks the signature", ctx do
      message = signed(@message, ctx.signer)
      tampered = String.replace(message, "From: Shop", "Subject: Free money\r\nFrom: Shop")
      assert Dkim.verify(tampered, ctx.public) == {:error, :bad_signature}
    end

    test "CH-36: a changed body fails the body hash", ctx do
      message = signed(@message, ctx.signer)
      assert Dkim.verify(message <> "P.S.\r\n", ctx.public) == {:error, :body_hash_mismatch}
    end

    test "CH-36: refolded header white space still verifies under relaxed", ctx do
      message = signed(@message, ctx.signer)
      refolded = String.replace(message, "To: reader@example.com", "To:\r\n   reader@example.com")
      assert Dkim.verify(refolded, ctx.public) == :ok
    end

    test "CH-36: an expiry is written as x=", ctx do
      assert {:ok, field} = Dkim.sign(@message, params(%{expires: 1_794_000_000}), ctx.signer)
      assert Dkim.tags(field)["x"] == "1794000000"
    end

    test "CH-38: a message without a required field is not signed", ctx do
      line = "List-Unsubscribe-Post: List-Unsubscribe=One-Click\n"
      message = String.replace(@message, line, "")

      assert {:error, %Relay.Error{code: :dkim_header_missing}} =
               Dkim.sign(message, params(), ctx.signer)
    end

    test "CH-36: a signer error is returned as it is" do
      failing = fn _data -> {:error, Relay.Error.new(:key_not_found, "no key")} end

      assert {:error, %Relay.Error{code: :key_not_found}} =
               Dkim.sign(@message, params(), failing)
    end
  end

  describe "CH-36 keys" do
    test "CH-36: keys under 2048 bits are refused", ctx do
      assert Dkim.check_key(ctx.modulus) == :ok
      assert Dkim.key_bits(ctx.modulus) == 2048

      {:ok, {:RSAPublicKey, small, _exponent}} = Dkim.decode_spki(Base.decode64!(@rfc8463_p))
      assert Dkim.key_bits(small) == 1024
      assert {:error, %Relay.Error{code: :dkim_key_too_short}} = Dkim.check_key(small)
    end

    test "CH-36: the key store signer refuses a key it does not hold" do
      assert {:error, %Relay.Error{}} = Dkim.key_signer("dkim-test-missing")
    end

    test "CH-36: the DNS record is split into strings of at most 255 bytes", ctx do
      strings = Dkim.dns_record({ctx.modulus, ctx.exponent})

      assert length(strings) >= 2
      assert Enum.all?(strings, &(byte_size(&1) <= 255))

      tags = strings |> Enum.join() |> Dkim.tags()
      assert tags["v"] == "DKIM1" and tags["k"] == "rsa"
      assert {:ok, {:RSAPublicKey, modulus, _e}} = Dkim.decode_spki(Base.decode64!(tags["p"]))
      assert modulus == ctx.modulus
    end
  end
end
