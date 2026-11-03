defmodule Relay.Templates.LocaleTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Locale

  describe "TP-25 recipient locale" do
    test "TP-25: profile, then device, then the tenant default" do
      assert Locale.recipient(%{profile: "de", device: "fr", tenant_default: "tr"}) ==
               {:ok, "de", :profile}

      assert Locale.recipient(%{device: "fr-fr", tenant_default: "tr"}) == {:ok, "fr-FR", :device}
      assert Locale.recipient(%{profile: "not a tag", tenant_default: "tr"}) ==
               {:ok, "tr", :tenant_default}
    end

    test "TP-25: Accept-Language counts only on the inbox and web surfaces" do
      candidates = %{accept_language: "de-CH;q=0.8, en;q=0.9", tenant_default: "tr"}

      on = fn surface -> Locale.recipient(Map.put(candidates, :surface, surface)) end

      assert Locale.recipient(candidates) == {:ok, "tr", :tenant_default}
      assert on.(:send) == {:ok, "tr", :tenant_default}
      assert on.(:inbox) == {:ok, "en", :accept_language}
      assert on.(:web) == {:ok, "en", :accept_language}
    end

    test "TP-25: Accept-Language ranges by weight, without wildcards" do
      assert Locale.accept_language("de-CH;q=0.8, en;q=0.9, *;q=0.1, fr") == ["fr", "en", "de-CH"]
      assert Locale.accept_language("tr;q=0, en") == ["en"]
      assert Locale.accept_language(nil) == []
    end
  end

  describe "TP-26 fallback chain" do
    test "TP-26: the truncation chain" do
      assert Locale.chain("tr-TR") == ["tr-TR", "tr"]
      assert Locale.chain("zh-Hant-TW") == ["zh-Hant-TW", "zh-Hant", "zh"]
      assert Locale.chain("en-x-private") == ["en-x-private", "en"]
    end

    test "TP-26: tr-TR finds the tr cell without counting a fallback" do
      candidates = %{profile: "tr-TR", tenant_default: "en"}
      assert {:ok, resolution} = Locale.resolve(candidates, ["tr", "en"])

      assert resolution == %{
               locale: "tr",
               requested: "tr-TR",
               source: :profile,
               template_locale_missing: false
             }
    end

    test "TP-26: a locale without a cell falls back to the tenant default and is counted" do
      candidates = %{profile: "de", tenant_default: "tr"}
      assert {:ok, resolution} = Locale.resolve(candidates, ["tr", "en"])

      assert resolution == %{
               locale: "tr",
               requested: "de",
               source: :tenant_default,
               template_locale_missing: true
             }
    end

    test "TP-26: a recipient without a locale gets the tenant default without a count" do
      assert {:ok, resolution} = Locale.resolve(%{tenant_default: "tr-TR"}, ["tr"])

      assert resolution == %{
               locale: "tr",
               requested: nil,
               source: :tenant_default,
               template_locale_missing: false
             }
    end

    test "TP-26: no cell in the chain stops the render and there is no system default" do
      assert Locale.resolve(%{profile: "de", tenant_default: "fr"}, ["tr", "en"]) ==
               {:error, :locale_missing}

      assert Locale.resolve(%{profile: "en", tenant_default: nil}, ["en"]) ==
               {:error, :locale_missing}
    end
  end

  describe "TP-56 supported locales" do
    test "TP-56: a locale is supported when its language is configured" do
      assert Locale.supported?("tr-TR")
      assert Locale.supported?("ar")
      refute Locale.supported?("ja")
      refute Locale.supported?("not a tag")
    end
  end
end
