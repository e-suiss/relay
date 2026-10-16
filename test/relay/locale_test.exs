defmodule Relay.LocaleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Locale

  @valid %{
    "tr" => "tr",
    "tr-TR" => "tr-TR",
    "TR-tr" => "tr-TR",
    "en-us" => "en-US",
    "zh-hant-tw" => "zh-Hant-TW",
    "sr-LATN-rs" => "sr-Latn-RS",
    "es-419" => "es-419",
    "de-CH-1901" => "de-CH-1901",
    "sl-rozaj-biske" => "sl-rozaj-biske",
    "zh-yue-HK" => "zh-yue-HK",
    "de-DE-u-co-phonebk" => "de-DE-u-co-phonebk",
    "en-US-x-Twain" => "en-US-x-twain",
    "en-a-bbb-x-a-ccc" => "en-a-bbb-x-a-ccc",
    "haw" => "haw"
  }

  describe "TN-2 C-57 BCP 47" do
    test "TN-2: well-formed tags are accepted in canonical letter case" do
      for {tag, canonical} <- @valid do
        assert Locale.new(tag) == {:ok, canonical}, tag
      end
    end

    test "C-57: malformed, grandfathered and private-use-only tags are refused" do
      for tag <- [
            "",
            "tr_TR",
            "e",
            "en--US",
            "en-US-",
            "-en",
            "toolongtag",
            "x-private",
            "i-klingon",
            "de-1901-1901",
            "en-a-bbb-a-ccc",
            "en-a",
            "en-x",
            "en-US-a",
            "tr-TR@euro",
            "türk",
            nil,
            :tr
          ] do
        assert {:error, %Relay.Error{code: :invalid_locale}} = Locale.new(tag), inspect(tag)
      end
    end

    property "C-57: letter case never changes the result and canonical tags are fixed points" do
      check all {tag, canonical} <- member_of(Map.to_list(@valid)),
                flips <- list_of(boolean(), length: String.length(tag)) do
        mixed =
          tag
          |> String.graphemes()
          |> Enum.zip(flips)
          |> Enum.map_join(fn {char, up} ->
            if up, do: String.upcase(char), else: String.downcase(char)
          end)

        assert Locale.new(mixed) == {:ok, canonical}
        assert Locale.new(canonical) == {:ok, canonical}
      end
    end
  end
end
