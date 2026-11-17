defmodule Relay.Compliance.SmsKeywordTest do
  use ExUnit.Case, async: true

  alias Relay.Compliance

  @refusals ~w(RET IPTAL İPTAL DUR H)
  @stops ["STOP", "QUIT", "END", "REVOKE", "OPT OUT", "CANCEL", "UNSUBSCRIBE"]
  @us %{scope: "all_channel", channels: ["sms", "voice"]}
  @marketing %{scope: "all_marketing", channels: ["sms"]}

  defp table, do: elem(Compliance.bundled_table(), 1)

  defp scopes(number) do
    code = Relay.Phone.calling_code(number)

    for country <- Compliance.candidates(table(), code, nil),
        do: Compliance.revocation_scope(table(), country, "sms")
  end

  describe "PC-37 the keyword sets" do
    test "PC-37: every keyword of the four sets is read, whatever the provider" do
      for keyword <- @refusals,
          do: assert({:tr_refusal, _canonical} = Compliance.sms_keyword(keyword))

      for keyword <- @stops, do: assert(Compliance.sms_keyword(keyword) == {:stop, keyword})
      assert Compliance.sms_keyword("HELP") == {:help, "HELP"}
      assert Compliance.sms_keyword("YARDIM") == {:help, "YARDIM"}
      assert Compliance.sms_keyword("START") == {:restart, "START"}
      assert Compliance.sms_keyword("UNSTOP") == {:restart, "UNSTOP"}
    end

    test "PC-37: matching folds the Turkish letters and ignores case and surrounding space" do
      for text <- ["iptal", "İptal", "IPTAL", "ıptal", "  İPTAL \n"],
          do: assert(Compliance.sms_keyword(text) == {:tr_refusal, "IPTAL"})

      for text <- ["yardım", "YARDIM", "Yardim"],
          do: assert(Compliance.sms_keyword(text) == {:help, "YARDIM"})

      for text <- ["quit", "Quıt", "QUİT"],
          do: assert(Compliance.sms_keyword(text) == {:stop, "QUIT"})

      assert Compliance.sms_keyword("ret") == {:tr_refusal, "RET"}
      assert Compliance.sms_keyword("h") == {:tr_refusal, "H"}
      assert Compliance.sms_keyword("opt   out") == {:stop, "OPT OUT"}
      assert Compliance.sms_keyword("Stop.") == {:stop, "STOP"}
      assert Compliance.sms_keyword("STOP!!") == {:stop, "STOP"}
    end

    test "PC-37: only a whole message is a keyword" do
      for text <- ["", "stop please", "please stop", "RET 123", "STOPP", "hello", "H?"],
          do: assert(Compliance.sms_keyword(text) == :none)

      assert Compliance.sms_keyword(String.duplicate(" ", 80) <> "STOP") == :none
      assert Compliance.sms_keyword(<<0xFF, 0xFE>>) == :none
      assert Compliance.sms_keyword(nil) == :none
    end
  end

  describe "PC-39 the scope of a refusal keyword" do
    test "PC-39, PC-40: STOP from a number of the United States covers SMS and voice" do
      assert @us in scopes("+12025550123")
      assert Compliance.sms_revocation(:stop, scopes("+12025550123")) == @us
    end

    test "PC-39: every other refusal keyword is a refusal of the brand's marketing on SMS" do
      assert Compliance.sms_revocation(:stop, scopes("+905551112233")) == @marketing
      assert Compliance.sms_revocation(:stop, scopes("+4915112345678")) == @marketing
      assert Compliance.sms_revocation(:stop, []) == @marketing
      assert Compliance.sms_revocation(:tr_refusal, [@us]) == @marketing
    end
  end

  describe "PC-37 the replies" do
    test "PC-37: a reply is one GSM 7 bit segment without marketing content, Turkish or English" do
      for kind <- [:refused, :help, :restarted], locale <- ["tr", "tr-TR", "en", "de", nil] do
        text = Compliance.sms_reply(kind, locale, "ACMEACMEACM")

        assert String.starts_with?(text, "ACMEACMEACM: ")
        assert String.length(text) <= 160
        assert text =~ ~r/\A[A-Za-z0-9 .,:]+\z/
      end

      assert Compliance.sms_reply(:refused, "tr", nil) =~ "Ret talebiniz alindi"
      assert Compliance.sms_reply(:refused, "en-US", nil) =~ "unsubscribed"
      assert Compliance.sms_reply(:help, "tr", nil) =~ "RET"
      assert Compliance.sms_reply(:help, nil, nil) =~ "STOP"
      assert Compliance.sms_reply(:restarted, "en", "") =~ "subscribed again"
    end
  end
end
