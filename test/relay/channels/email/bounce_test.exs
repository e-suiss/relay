defmodule Relay.Channels.Email.BounceTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.Mime
  alias Relay.Channels.Email.StatusCode
  alias Relay.Datasets.Package

  @hour 3_600_000
  @examples [
    {{5, 1, 1}, :hard, "permanent_target"},
    {{5, 1, 10}, :hard, "permanent_target"},
    {{5, 2, 1}, :hard, "permanent_target"},
    {{4, 2, 2}, :soft, "transient"},
    {{5, 2, 2}, :soft, "transient"},
    {{5, 7, 26}, :sender_config, "sender_config"},
    {{5, 7, 515}, :sender_config, "sender_config"},
    {{5, 7, 27}, :sender_config, "sender_config"},
    {{5, 7, 30}, :sender_config, "sender_config"},
    {{5, 7, 1}, :policy, "permanent_content"}
  ]

  defp table, do: Bundled.content("email_bounce_codes")

  defp recipient(status, diagnostic, action \\ "failed") do
    %{
      final_recipient: Relay.Redacted.wrap("someone@example.com"),
      original_recipient: nil,
      action: action,
      status: status,
      status_text: status && StatusCode.to_string(status),
      diagnostic_type: "smtp",
      diagnostic: diagnostic && Relay.Redacted.wrap(diagnostic),
      remote_mta: nil,
      will_retry_until: nil
    }
  end

  describe "CH-39 bounce kinds" do
    test "CH-39: the spec's examples map to their kinds and failure classes" do
      for {status, kind, class} <- @examples do
        result = Bounce.classify(recipient(status, nil), table())
        assert {result.kind, result.failure_class} == {kind, class}, inspect(status)
      end
    end

    test "CH-39: sender_config never suppresses and never counts toward reputation" do
      result = Bounce.classify(recipient({5, 7, 26}, "550 5.7.26 DMARC"), table())

      assert result.suppression == nil
      assert result.reputation == nil
      assert Bounce.subscriber_untouched?(result)
    end

    test "CH-40: a hard bounce suppresses without end; a soft bounce counts" do
      assert %{suppression: "hard_bounce", reputation: :bounce} =
               Bounce.classify(recipient({5, 1, 1}, nil), table())

      assert %{suppression: "soft_bounce", reputation: nil} =
               Bounce.classify(recipient({4, 4, 7}, nil), table())
    end

    test "CH-8: an unmapped status is unknown and raises provider.unknown_code" do
      result = Bounce.classify(recipient({5, 3, 0}, "550 something else"), table())

      assert %{kind: :unknown, failure_class: "unknown", suppression: nil, rule: nil} = result
      assert Bounce.unknown_code?(result)
    end

    test "CH-39: a generic X.0.0 status takes the specific code its diagnostic names" do
      result = Bounce.classify(recipient({5, 0, 0}, "550 5.1.1 <a@example.com> unknown"), table())
      assert %{kind: :hard, status: "5.1.1", rule: "code:5.1.1"} = result
    end

    test "CH-39: a missing status takes the code of its diagnostic" do
      result = Bounce.classify(recipient(nil, "smtp; 552 5.2.2 over quota"), table())
      assert %{kind: :soft, status: "5.2.2"} = result
    end

    test "CH-39: a dialect never turns a transient status into a hard bounce" do
      result = Bounce.classify(recipient({4, 0, 0}, "450 user unknown, try later"), table())
      assert %{kind: :soft, rule: "prefix:4"} = result
    end

    test "CH-39: delayed and delivered recipients are outcomes, not failures" do
      assert %{kind: :delayed, failure_class: nil} =
               Bounce.classify(recipient({4, 0, 0}, nil, "delayed"), table())

      assert %{kind: :delivered, failure_class: nil} =
               Bounce.classify(recipient({2, 0, 0}, nil, "delivered"), table())
    end
  end

  describe "CH-40 soft bounce window" do
    @params %{"window_ms" => 72 * @hour, "count" => 3}

    test "CH-40: below the count inside the window a soft bounce only counts" do
      now = 100 * @hour
      assert Bounce.soft_bounce([], now, @params) == :count
      assert Bounce.soft_bounce([now - 10 * @hour], now, @params) == :count
    end

    test "CH-40: soft bounces outside the window do not count" do
      now = 200 * @hour
      old = [now - 73 * @hour, now - 80 * @hour]
      assert Bounce.soft_bounce(old, now, @params) == :count
    end

    test "CH-40: the third soft bounce in 72 hours suppresses for the configured time" do
      now = 300 * @hour
      earlier = [now - 70 * @hour, now - 1 * @hour]

      assert Bounce.soft_bounce(earlier, now, Map.put(@params, "suppress_ms", 24 * @hour)) ==
               {:suppress, now + 24 * @hour}
    end

    test "CH-40: without a configured duration no timed suppression is written" do
      now = 300 * @hour
      assert Bounce.soft_bounce([now - 2, now - 1], now, @params) == :no_duration
    end

    test "CH-40, CH-85: the bundled parameters are 3 soft bounces in 72 hours, suppressed 7 days" do
      assert %{"window_ms" => 259_200_000, "count" => 3, "suppress_ms" => 604_800_000} =
               Bundled.content("email_reputation")["soft_bounce"]
    end
  end

  describe "OP-65 e-mail data sets" do
    test "CH-37: the bundled e-mail data sets are valid versions of their schemas" do
      assert {:ok, datasets} = Package.read(Package.root())
      names = Enum.map(datasets, & &1.name)

      for name <- Bundled.names(), do: assert(name in names, name)
    end

    test "CH-39: every bounce code row names a kind and a source, and codes are unique" do
      codes = Enum.map(table()["codes"], & &1["code"])
      assert codes == Enum.uniq(codes)
      assert Enum.all?(table()["codes"] ++ table()["dialects"], &(&1["source"] != ""))
    end
  end

  describe "RFC 3463 status codes" do
    test "CH-39: codes are parsed and found in text, dotted addresses are not" do
      assert StatusCode.parse("5.1.10") == {:ok, {5, 1, 10}}
      assert StatusCode.parse("3.1.1") == :error
      assert StatusCode.find("550-5.7.26 Unauthenticated") == {:ok, {5, 7, 26}}
      assert StatusCode.find("host 10.5.1.1 refused") == :error
      assert StatusCode.find("ended with 4.2.2.") == {:ok, {4, 2, 2}}
      assert StatusCode.reply_code("smtp; 550 5.1.1 unknown") == {:ok, 550}
      assert StatusCode.class({4, 7, 0}) == :transient
    end
  end

  describe "RFC 5322 reading" do
    test "CH-39: header fields are unfolded and multipart bodies are split on their boundary" do
      message =
        "Content-Type: multipart/mixed;\n boundary=\"b1\"\nSubject: a\n b\n\npreamble\n--b1\n" <>
          "Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\naGVsbG8=\n--b1\n" <>
          "Content-Transfer-Encoding: quoted-printable\n\nsoft=\nbreak =3D ok\n--b1--\n"

      part = Mime.parse(message)
      assert Mime.header(part.headers, "subject") == "a b"
      assert {"multipart/mixed", %{"boundary" => "b1"}} = Mime.content_type(part.headers)

      assert [first, second] = Mime.parts(part.body, "b1")
      assert Mime.decoded(first) == "hello"
      assert Mime.decoded(second) == "softbreak = ok"
    end
  end
end
