defmodule Relay.Templates.ConvertTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Convert

  @cases "test/fixtures/template_conversion/cases.json" |> File.read!() |> Jason.decode!()

  defp language("liquid"), do: :liquid
  defp language("handlebars"), do: :handlebars

  describe "OP-96 template conversion" do
    for %{"name" => name} = entry <- @cases do
      @entry entry
      test "OP-96, OP-55: golden case #{name}" do
        %{"language" => language, "source" => source, "aliases" => aliases} = @entry
        result = Relay.Templates.convert(language(language), source, aliases)
        codes = Enum.map(result.findings, & &1.code)

        assert result.status == @entry["status"], inspect(result)
        assert result.output == @entry["output"], inspect(result)
        for code <- @entry["codes"], do: assert(code in codes, inspect(result))
      end
    end

    test "OP-96: every converted output parses in the Relay template engine" do
      for %{"language" => language, "source" => source, "aliases" => aliases} <- @cases do
        result = Relay.Templates.convert(language(language), source, aliases)

        if result.output do
          raw = String.contains?(result.output, "| raw")
          assert {:ok, _template} = Relay.Templates.parse(result.output, allow_raw: raw)
        end
      end
    end

    test "OP-96: an alias that a template uses is reported" do
      result = Relay.Templates.convert(:liquid, "{{ old.name }}", %{"old" => "subscriber"})
      assert result.output == "{{ subscriber.name }}"
      assert result.aliases == ["old"]
    end

    test "OP-55 (9): a source that is not valid UTF-8 cannot be converted" do
      result = Relay.Templates.convert(:handlebars, <<0xFF, 0xFE>>, %{})
      assert %{status: "CANNOT", output: nil} = result
      assert [%{code: "invalid_utf8"}] = result.findings
    end

    test "OP-96: a status follows the most severe finding" do
      assert Convert.status([]) == "AUTO_OK"
      assert Convert.status([{:info, "x", nil, ""}]) == "AUTO_OK"
      assert Convert.status([{:review, "x", 1, ""}]) == "NEEDS_REVIEW"

      assert Convert.status([{:review, "x", 1, ""}, {:cannot, "y", 2, ""}]) == "CANNOT"
    end
  end
end
