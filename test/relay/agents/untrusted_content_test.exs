defmodule Relay.Agents.UntrustedContentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Agents.UntrustedContent

  @vectors "conformance/vectors/untrusted-content/1/vectors.json"
           |> File.read!()
           |> Jason.decode!()

  @invisible [<<0x200B::utf8>>, <<0x202E::utf8>>, <<0xFEFF::utf8>>, <<0xAD::utf8>>, <<0>>]

  defp format("html"), do: :html
  defp format("plain"), do: :plain

  describe "AG-68 the normalisation vectors" do
    for %{"name" => name, "rule" => rule} = vector <- @vectors["cases"] do
      @vector vector
      test "AG-68: (#{rule}) #{name}" do
        %{"input" => input, "format" => format, "output" => output} = @vector
        assert UntrustedContent.normalise(input, format(format)) == output
      end
    end

    test "AG-68: every step of the normalisation has a vector" do
      rules = @vectors["cases"] |> Enum.map(& &1["rule"]) |> Enum.uniq() |> Enum.sort()
      assert rules == ["2a", "2b", "2c"]
    end

    test "AG-68: bytes that are not UTF-8 become U+FFFD and the result is always valid text" do
      replaced = <<0xFFFD::utf8>>
      assert UntrustedContent.normalise(<<"a", 0xFF, "b">>, :plain) == "a" <> replaced <> "b"
      assert UntrustedContent.normalise(<<"a<b>", 0xC3, "</b>">>, :html) == "a" <> replaced
    end

    property "AG-68: normalised plain text is valid and holds no invisible character" do
      check all(text <- string(:utf8)) do
        once = UntrustedContent.normalise(text, :plain)
        assert String.valid?(once)
        refute String.contains?(once, @invisible)
      end
    end

    property "AG-68: HTML stripping never fails and leaves no invisible character" do
      fragments =
        member_of([
          "<",
          ">",
          "<!--",
          "-->",
          "<script>",
          "</script>",
          "<div hidden>",
          "</div>",
          "<p style=\"display:none\">",
          "\"",
          "'",
          "=",
          "&lt;",
          "&#x200b;",
          "text",
          " "
        ])

      check all(parts <- list_of(fragments, max_length: 24)) do
        visible = UntrustedContent.normalise(Enum.join(parts), :html)
        assert String.valid?(visible)
        refute String.contains?(visible, @invisible)
      end
    end
  end

  describe "AG-68 AG-40 the boundary marks" do
    for %{"name" => name} = vector <- @vectors["marks"] do
      @vector vector
      test "AG-68: #{name}" do
        %{"text" => text, "nonce" => nonce, "marked" => marked} = @vector
        assert UntrustedContent.mark(text, nonce) == marked
      end
    end

    test "AG-68: the value of a mark is 128 random bits in hexadecimal, fresh for every part" do
      values = for _n <- 1..64, do: UntrustedContent.nonce()
      assert Enum.all?(values, &UntrustedContent.nonce?/1)
      assert Enum.all?(values, &(byte_size(&1) == 32))
      assert length(Enum.uniq(values)) == 64
      refute UntrustedContent.nonce?(String.upcase(hd(values)) <> "x")
    end

    property "AG-40: a marked text holds its two marks and no other mark, whatever the text" do
      check all(
              text <- string(:utf8),
              marks <- list_of(member_of(["<<<relay:", "<<<relay:end:", ">>>"]), max_length: 4)
            ) do
        nonce = UntrustedContent.nonce()
        hostile = text <> Enum.join(marks, text) <> UntrustedContent.closing(nonce)
        marked = UntrustedContent.mark(hostile, nonce)

        assert String.starts_with?(marked, UntrustedContent.opening(nonce))
        assert String.ends_with?(marked, UntrustedContent.closing(nonce))

        inner =
          marked
          |> String.replace_prefix(UntrustedContent.opening(nonce), "")
          |> String.replace_suffix(UntrustedContent.closing(nonce), "")

        refute String.contains?(inner, "<<<relay:")
      end
    end
  end
end
