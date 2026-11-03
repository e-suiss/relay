defmodule Relay.Templates.Sms.EncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Sms.Encoding
  alias Relay.Templates.Sms.Segments

  @basic_text "@£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
  @basic String.graphemes(@basic_text)

  defp segments(text, encoding) do
    {:ok, units} = Encoding.units(text, encoding)
    Segments.count(units, encoding)
  end

  describe "TP-18 CH-48 GSM 03.38 tables" do
    test "the default alphabet has 125 printable characters plus line feed and carriage return" do
      assert length(@basic) == 125
      assert Enum.all?(@basic, &(Encoding.units(&1, :gsm7) == {:ok, [1]}))
      assert Encoding.units("\n\r", :gsm7) == {:ok, [1, 1]}
    end

    test "extension characters cost two septets" do
      for char <- ~w(^ { } \\ [ ] ~ | €) do
        assert Encoding.units(char, :gsm7) == {:ok, [2]}, char
        assert Encoding.units(char, :gsm7_tr) == {:ok, [2]}, char
      end
    end

    test "Turkish single shift: ç ğ Ğ ı İ ş Ş and, conservatively, Ç cost two septets" do
      for char <- ~w(ç ğ Ğ ı İ ş Ş Ç) do
        assert Encoding.units(char, :gsm7_tr) == {:ok, [2]}, char
      end

      for char <- ~w(Ö ö Ü ü) do
        assert Encoding.units(char, :gsm7_tr) == {:ok, [1]}, char
      end

      assert Encoding.units("Ç", :gsm7) == {:ok, [1]}
      assert Encoding.units("ş", :gsm7) == :error
    end

    test "UCS-2 counts a character above the Basic Multilingual Plane as a surrogate pair" do
      assert Encoding.units("a😀", :ucs2) == {:ok, [1, 2]}
    end

    test "the backtick and the euro sign differ: one is unsupported, the other an escape" do
      assert Encoding.units("`", :gsm7) == :error
      assert Encoding.unsupported("a`b`ş", :gsm7) == [
               %{codepoint: ?`, count: 2},
               %{codepoint: ?ş, count: 1}
             ]
    end

    test "names are explicit" do
      assert Enum.map([:gsm7, :gsm7_tr, :ucs2], &Encoding.name/1) == ["GSM7", "GSM7_TR", "UCS2"]
    end
  end

  describe "TP-18 encoding choice" do
    test "default alphabet text is GSM7 under every policy" do
      for policy <- [:transliterate, :turkish_shift, :ucs2] do
        assert Encoding.choose("Hello Çok güzel", policy) == :gsm7
      end
    end

    test "Turkish text is GSM7_TR under turkish_shift and UCS2 under ucs2" do
      assert Encoding.choose("Şifreniz değişti", :turkish_shift) == :gsm7_tr
      assert Encoding.choose("Şifreniz değişti", :ucs2) == :ucs2
    end

    test "an emoji forces UCS2" do
      assert Encoding.choose("Kargonuz yolda 🚚", :turkish_shift) == :ucs2
    end
  end

  describe "TP-18 CH-48 segment vectors" do
    test "pure GSM text: 160 characters are one segment, 161 are two" do
      assert segments(String.duplicate("a", 160), :gsm7) == 1
      assert segments(String.duplicate("a", 161), :gsm7) == 2
      assert segments(String.duplicate("a", 306), :gsm7) == 2
      assert segments(String.duplicate("a", 307), :gsm7) == 3
    end

    test "extension characters count double" do
      assert segments(String.duplicate("€", 80), :gsm7) == 1
      assert segments(String.duplicate("€", 81), :gsm7) == 2
      assert segments(String.duplicate("[]", 40), :gsm7) == 1
      assert segments(String.duplicate("{}", 40) <> "a", :gsm7) == 2
    end

    test "an escape pair never straddles two segments" do
      text = String.duplicate("a", 152) <> "€" <> String.duplicate("a", 152)
      assert segments(text, :gsm7) == 3
    end

    test "GSM7_TR holds 155 septets in one segment and 149 per concatenated segment" do
      assert segments(String.duplicate("ş", 77) <> "a", :gsm7_tr) == 1
      assert segments(String.duplicate("ş", 78), :gsm7_tr) == 2
      assert segments(String.duplicate("a", 155), :gsm7_tr) == 1
      assert segments(String.duplicate("a", 298), :gsm7_tr) == 2
      assert segments(String.duplicate("a", 299), :gsm7_tr) == 3
    end

    test "UCS-2 holds 70 units in one segment and 67 per concatenated segment" do
      assert segments(String.duplicate("ş", 70), :ucs2) == 1
      assert segments(String.duplicate("ş", 71), :ucs2) == 2
      assert segments(String.duplicate("ş", 134), :ucs2) == 2
      assert segments(String.duplicate("ş", 135), :ucs2) == 3
      assert segments(String.duplicate("😀", 35), :ucs2) == 1
    end

    test "a surrogate pair never straddles two segments" do
      text = String.duplicate("a", 66) <> "😀" <> String.duplicate("a", 66)
      assert segments(text, :ucs2) == 3
    end

    test "reserved prefix units count before the text" do
      {:ok, units} = Encoding.units(String.duplicate("a", 158), :gsm7)
      assert Segments.count(units, :gsm7, 2) == 1
      assert Segments.count(units, :gsm7, 3) == 2
    end

    test "empty text takes no segment" do
      assert Segments.count([], :gsm7) == 0
    end

    test "capacity" do
      assert Segments.capacity(:gsm7, 1) == 160
      assert Segments.capacity(:gsm7, 2) == 306
      assert Segments.capacity(:gsm7_tr, 3, 10) == 437
      assert Segments.capacity(:ucs2, 1, 100) == 0
    end
  end

  describe "TP-18 properties" do
    property "default alphabet text follows the 160/153 formula" do
      check all chars <- list_of(member_of(@basic), max_length: 700) do
        n = length(chars)
        expected = if n <= 160, do: min(n, 1), else: div(n + 152, 153)
        assert segments(Enum.join(chars), :gsm7) == expected
      end
    end

    property "packing stays between the ideal and the one-unit-short bound" do
      check all units <- list_of(member_of([1, 2]), min_length: 1, max_length: 900),
                encoding <- member_of([:gsm7, :gsm7_tr, :ucs2]) do
        {single, per} = Segments.limits(encoding)
        total = Enum.sum(units)
        count = Segments.count(units, encoding)

        if total <= single do
          assert count == 1
        else
          assert count >= div(total + per - 1, per)
          assert count <= div(total + per - 2, per - 1)
        end
      end
    end

    property "every string fits UCS2 and the choice always carries the text" do
      check all text <- string(:printable, max_length: 200),
                policy <- member_of([:transliterate, :turkish_shift, :ucs2]) do
        assert Encoding.fits?(text, :ucs2)
        assert Encoding.fits?(text, Encoding.choose(text, policy))
      end
    end
  end
end
