defmodule Relay.Templates.Channel.PushTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Channel.Push

  describe "TP-20 push payload" do
    test "plain title, subtitle and body are built with the JSON encoder" do
      title = ~s(Siparişiniz "yolda")
      fields = %{"title" => title, "subtitle" => "Kargo", "body" => "Yarın teslim"}
      assert {:ok, %{output: output, changes: []}} = Push.render(fields, :personal)

      assert Jason.decode!(output.payload) == %{
               "aps" => %{
                 "alert" => %{
                   "title" => title,
                   "subtitle" => "Kargo",
                   "body" => "Yarın teslim"
                 }
               }
             }

      assert output.bytes == byte_size(output.payload)
      assert output.in_app_body == nil
    end

    test "an absent subtitle stays out of the payload" do
      assert {:ok, %{output: output}} = Push.render(%{"title" => "T", "body" => "B"}, :public)
      assert Jason.decode!(output.payload)["aps"]["alert"] == %{"title" => "T", "body" => "B"}
    end

    test "a payload over 4096 bytes is rejected, never cut" do
      body = String.duplicate("ş", 1024)
      fields = %{"title" => "T", "body" => body, "subtitle" => String.duplicate("ğ", 1024)}

      assert {:error, [%{check: :push_payload_size, level: :hard, detail: %{limit: 4096}}]} =
               Push.render(fields, :public)
    end

    test "a field over 1024 UTF-16 code units is rejected" do
      fields = %{"title" => "T", "body" => String.duplicate("😀", 513)}

      assert {:error, [%{check: :push_characters, pointer: "/body", detail: detail}]} =
               Push.render(fields, :public)

      assert detail == %{characters: 1026, limit: 1024}
      longest = %{"title" => "T", "body" => String.duplicate("a", 1024)}
      assert {:ok, _result} = Push.render(longest, :public)
    end

    test "invalid UTF-8 is removed and recorded as a sanitizer change" do
      fields = %{"title" => <<"Ti", 0xFF, "tle">>, "body" => "B"}

      assert {:ok, %{output: %{title: "Title"}, changes: [change]}} = Push.render(fields, :public)
      assert %{rule: :invalid_utf8, field: "title", count: 1} = change
    end

    test "a missing body is a hard finding" do
      assert {:error, [%{check: :push_body_missing, pointer: "/body"}]} =
               Push.render(%{"title" => "T"}, :public)
    end

    test "the publish gate reports the worst case as hard findings" do
      worst = %{"body" => String.duplicate("a", 1025)}

      assert [%{check: :push_characters, level: :hard, locale: "tr"}] =
               Push.publish_findings(worst, :public, locale: "tr")

      assert Push.publish_findings(%{"body" => "ok"}, :public) == []
    end
  end

  describe "TP-21 sensitive push" do
    test "the lock screen gets the neutral body, the full content stays in the app" do
      fields = %{
        "title" => "Bildirim",
        "lock_screen_body" => "Yeni bir mesajınız var",
        "in_app_body" => "Tahlil sonucunuz hazır",
        "body" => "ignored"
      }

      assert {:ok, %{output: output}} = Push.render(fields, :sensitive)
      assert output.body == "Yeni bir mesajınız var"
      assert output.in_app_body == "Tahlil sonucunuz hazır"
      refute output.payload =~ "Tahlil"
      refute output.payload =~ "ignored"
    end

    test "a sensitive variant without either body is rejected" do
      assert {:error, [%{pointer: "/lock_screen_body"}]} =
               Push.render(%{"title" => "T", "in_app_body" => "x"}, :sensitive)

      assert {:error, [%{pointer: "/in_app_body"}]} =
               Push.render(%{"title" => "T", "lock_screen_body" => "x"}, :sensitive)
    end
  end

  describe "TP-20 properties" do
    property "an accepted payload is valid JSON within 4096 bytes" do
      check all title <- string(:printable, max_length: 300),
                body <- string(:utf8, min_length: 1, max_length: 1500) do
        case Push.render(%{"title" => title, "body" => body}, :public) do
          {:ok, %{output: output}} ->
            assert output.bytes <= 4096
            assert %{"aps" => %{"alert" => _alert}} = Jason.decode!(output.payload)

          {:error, findings} ->
            assert [%Relay.Templates.Finding{} | _] = findings
        end
      end
    end

    test "utf16_length counts surrogate pairs" do
      assert Push.utf16_length("aş😀") == 4
    end
  end
end
