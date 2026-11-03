defmodule Relay.Templates.Channel.EmailTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Channel.Email

  @skeleton ~s(<html lang="tr"><head><meta name="color-scheme" content="light dark"></head><body>)

  defp fields(overrides \\ %{}) do
    Map.merge(
      %{
        "subject" => "Siparişiniz kargoda",
        "preheader" => "Takip numaranız içeride",
        "html" => @skeleton <> "<p>Merhaba</p></body></html>",
        "text" => "Merhaba"
      },
      overrides
    )
  end

  defp decode_word("=?UTF-8?B?" <> rest),
    do: rest |> String.trim_trailing("?=") |> Base.decode64!()

  describe "TP-22 subject" do
    test "CR and LF runs become one space and are recorded" do
      assert {:ok, %{output: output, changes: changes}} =
               Email.render(fields(%{"subject" => "Bcc: x\r\n\r\nSipariş\nhazır"}))

      assert output.subject == "Bcc: x Sipariş hazır"
      assert [%{rule: :line_break, action: :replaced, count: 5, field: "subject"}] = changes
    end

    test "TP-57: a subject over 78 characters is a warning" do
      longest = fields(%{"subject" => String.duplicate("ş", 78)})
      assert {:ok, %{findings: []}} = Email.render(longest)

      assert {:ok, %{findings: [%{check: :email_subject_length, detail: detail} = finding]}} =
               Email.render(fields(%{"subject" => String.duplicate("ş", 79)}))

      assert finding.level == :warning

      assert detail == %{characters: 79, limit: 78}
    end

    test "a printable ASCII subject is not encoded" do
      assert Email.encode_subject("Your order shipped") == "Your order shipped"
    end

    test "a non-ASCII subject becomes RFC 2047 B encoded-words" do
      encoded = Email.encode_subject("Şifreniz değişti")

      assert encoded == "=?UTF-8?B?" <> Base.encode64("Şifreniz değişti") <> "?="
    end

    property "encoded-words are at most 75 characters and decode to the subject" do
      check all subject <- string(:printable, min_length: 1, max_length: 200) do
        words = subject |> Email.encode_subject() |> String.split("\r\n ")

        if Regex.match?(~r/\A[\x20-\x7E]*\z/, subject) do
          assert words == [subject]
        else
          assert Enum.all?(words, &(String.length(&1) <= 75))
          assert Enum.map_join(words, &decode_word/1) == subject
        end
      end
    end
  end

  describe "TP-22 body" do
    test "a complete variant renders without findings" do
      assert {:ok, %{output: output, changes: [], findings: []}} =
               Email.render(fields(), locale: "tr")

      assert output.html_bytes == byte_size(output.html)
      assert output.dir == "ltr"
    end

    test "the plain text body is mandatory" do
      assert {:error, [%{check: :email_plain_text, level: :hard, pointer: "/text"}]} =
               Email.render(fields(%{"text" => "  "}))
    end

    test "HTML over 70 000 bytes warns and over 90 000 bytes is rejected" do
      padding = fn bytes -> @skeleton <> String.duplicate("a", bytes - byte_size(@skeleton)) end

      assert {:ok, %{findings: []}} = Email.render(fields(%{"html" => padding.(70_000)}))

      assert {:ok, %{findings: [%{check: :email_html_size, level: :warning}]}} =
               Email.render(fields(%{"html" => padding.(70_001)}))

      assert {:ok, %{findings: [%{check: :email_html_size, level: :warning}]}} =
               Email.render(fields(%{"html" => padding.(90_000)}))

      assert {:error, [%{check: :email_html_size, level: :hard, detail: %{bytes: 90_001}}]} =
               Email.render(fields(%{"html" => padding.(90_001)}))
    end

    test "a missing color-scheme meta tag is a warning" do
      html = ~s(<html lang="tr"><body>x</body></html>)

      assert {:ok, %{findings: [%{check: :email_color_scheme, level: :warning}]}} =
               Email.render(fields(%{"html" => html}))
    end

    test "AMP for Email is refused" do
      html = String.replace(@skeleton, "<html", "<html ⚡4email") <> "</body></html>"

      assert {:error, [%{check: :email_amp, level: :hard}]} =
               Email.render(fields(%{"html" => html}))

      html = String.replace(@skeleton, "<html", "<html amp4email") <> "</body></html>"
      assert {:error, [%{check: :email_amp}]} = Email.render(fields(%{"html" => html}))
    end

    test "the publish gate returns every finding" do
      worst = fields(%{"text" => "", "html" => "<html><body></body></html>"})
      findings = Email.publish_findings(worst)
      assert Enum.map(findings, & &1.check) == [:email_plain_text, :email_color_scheme]
    end
  end

  describe "TP-29 direction" do
    test "an RTL locale gets dir=rtl on the html element and the change is recorded" do
      assert {:ok, %{output: output, changes: changes, findings: []}} =
               Email.render(fields(), locale: "ar")

      assert output.html =~ ~s(<html dir="rtl" lang="tr">)
      assert output.dir == "rtl"
      assert [%{rule: :rtl_dir, action: :added, field: "html"}] = changes
    end

    test "an existing dir is kept" do
      html = ~s(<html dir="rtl" lang="ar"><head><meta name="color-scheme" content="light"></head>)
      assert {html, []} == Email.put_dir(html, "he")
    end

    test "an RTL locale without an html element is a warning" do
      html = ~s(<meta name="color-scheme" content="light"><p>x</p>)

      assert {:ok, %{findings: [%{check: :email_dir, level: :warning}], changes: []}} =
               Email.render(fields(%{"html" => html}), locale: "fa")
    end
  end
end
