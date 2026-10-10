defmodule RelayDev.CatalogTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Catalog

  @moduletag :tmp_dir

  defp catalog(dir, rules, enforced) do
    write!(dir, %{
      "conformance/catalog/rules.json" => Jason.encode!(rules),
      "conformance/catalog/progress.json" => Jason.encode!(%{enforced_stage: enforced})
    })
  end

  describe "T-81 T-61 rule catalog" do
    test "T-81: a test naming an unknown rule is rejected", %{tmp_dir: dir} do
      catalog(dir, [%{id: "INV-1", title: "x", verify_stage: 4}], 0)
      write!(dir, %{"test/a_test.exs" => ~s(test "INV-999: nothing" do\n)})

      assert [%{message: "test names unknown rule INV-999"}] = Catalog.check(dir)
    end

    test "T-61: a verified rule of an enforced stage needs a test and a title", %{tmp_dir: dir} do
      catalog(
        dir,
        [%{id: "INV-46", title: "", verify_stage: 0}, %{id: "INV-1", title: "", verify_stage: 4}],
        0
      )

      messages = dir |> Catalog.check() |> Enum.map(& &1.message)

      assert messages == [
               "INV-46 (stage 0): missing English title",
               "INV-46 (stage 0): no test names this rule"
             ]

      write!(dir, %{"test/a_test.exs" => ~s(describe "INV-46 strict config" do\n)})
      catalog(dir, [%{id: "INV-46", title: "Strict config", verify_stage: 0}], 0)
      assert Catalog.check(dir) == []
    end

    test "T-81: the generator reads register rows, statuses, stages and acceptance fields", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "spec/06-invariants.md" => """
        | ID | Karar | Statü | Gerekçe/kaynak |
        |---|---|---|---|
        | INV-46 | Strict | KANONİK DEĞİŞMEZ | x |
        """,
        "spec/19-technical-architecture.md" => """
        | ID | Kabul testi | Geçersiz kılacak karşı örnek |
        |---|---|---|
        | T-5 | `test/x_test.exs` | y |
        | T-45 | doldurulacak (Aşama 2) | y |

        | ID | Karar | Statü | Gerekçe/kaynak |
        |---|---|---|---|
        | T-5 | Exec | FROZEN (teknik) · PD (x) | y |
        | T-45 | Mem | FROZEN (teknik) | y |
        """,
        "spec/appendix-b-feature-inventory.md" => """
        ### Aşama 0 — Temel

        #### Bu aşamada doğrulanacak sınırlar
        - **INV-46, T-5 (1)** — x.

        ---
        """
      })

      rules =
        Catalog.generate(Path.join(dir, "spec"), [
          %{"id" => "INV-46", "title" => "Strict configuration"}
        ])

      assert [
               %{
                 "id" => "INV-46",
                 "status" => "canonical_invariant",
                 "verify_stage" => 0,
                 "title" => "Strict configuration"
               },
               %{
                 "id" => "T-5",
                 "status" => "frozen_technical",
                 "verify_stage" => 0,
                 "acceptance" => "defined"
               },
               %{"id" => "T-45", "acceptance" => "pending", "verify_stage" => nil}
             ] = rules
    end

    test "T-81: the repository catalog covers stage 0" do
      assert Catalog.check(File.cwd!()) == []
    end
  end
end
