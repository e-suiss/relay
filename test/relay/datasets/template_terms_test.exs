defmodule Relay.Datasets.TemplateTermsTest do
  use ExUnit.Case, async: true

  alias Relay.Datasets.Package

  @health_tr [
    "tanı",
    "teşhis",
    "reçete",
    "ilaç",
    "tahlil",
    "test sonucu",
    "hasta",
    "tedavi",
    "randevu",
    "kanser",
    "hiv",
    "hamile",
    "gebelik",
    "psikiyatri",
    "terapi"
  ]
  @finance_tr [
    "borc",
    "borç",
    "icra",
    "haciz",
    "bakiye",
    "kredi kart",
    "gecikme",
    "ödenmemiş",
    "temerrüt",
    "iban",
    "hesap numara",
    "maaş"
  ]
  @special_en ["religio", "sexual", "union member", "biometric"]
  @promotional_en [
    "promo code",
    "coupon code",
    "discount code",
    "use code",
    "shop now",
    "buy now",
    "add to cart",
    "limited time",
    "last chance",
    "don't miss",
    "while supplies last"
  ]

  defp versions(name) do
    dir = Path.join("priv/datasets", name)

    dir
    |> File.ls!()
    |> Enum.flat_map(fn file ->
      case Regex.run(~r/\Av([1-9][0-9]*)\.json\z/, file) do
        [_, n] -> [{String.to_integer(n), Path.join(dir, file)}]
        nil -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {_n, path} -> path |> File.read!() |> Jason.decode!() end)
  end

  defp terms(content, category, locale) do
    for %{"term" => term, "category" => ^category, "locale" => ^locale} <- content["terms"],
        do: term
  end

  describe "TP-46 sensitive terms" do
    test "TP-46: the bundled versions are valid and belong to their data sets" do
      assert {:ok, datasets} = Package.read(Package.root())
      names = Enum.map(datasets, & &1.name)
      assert "sensitive_terms" in names
      assert "promotional_terms" in names
    end

    test "TP-46: the initial content is the Turkish and English dictionary of the decision" do
      [first | _] = versions("sensitive_terms")

      assert terms(first, "health", "tr") == @health_tr
      assert terms(first, "finance", "tr") == @finance_tr
      assert "pregnan" in terms(first, "health", "en")
      assert terms(first, "special_category", "en") == @special_en
      assert "tckn" in terms(first, "identity_legal", "tr")
      assert length(first["terms"]) == 72
    end

    test "TP-46: a term is never removed from a later version, only deprecated" do
      for name <- ["sensitive_terms", "promotional_terms"] do
        key = if name == "sensitive_terms", do: "term", else: "phrase"
        field = if name == "sensitive_terms", do: "terms", else: "phrases"

        name
        |> versions()
        |> Enum.map(fn content -> MapSet.new(content[field], &{&1[key], &1["locale"]}) end)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [previous, next] -> assert MapSet.subset?(previous, next), name end)
      end
    end
  end

  describe "TP-54 promotional terms" do
    test "TP-54: the initial phrases are calls to action, not single words" do
      [first | _] = versions("promotional_terms")
      phrases = first["phrases"]

      assert for(%{"phrase" => p, "locale" => "en"} <- phrases, do: p) == @promotional_en
      assert %{"phrase" => "indirim kodu", "locale" => "tr"} in phrases
      assert Enum.all?(phrases, &String.contains?(&1["phrase"], " "))
      refute Enum.any?(phrases, &(&1["phrase"] in ["indirim", "kampanya", "discount"]))
    end
  end
end
