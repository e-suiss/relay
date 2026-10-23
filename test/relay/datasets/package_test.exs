defmodule Relay.Datasets.PackageTest do
  use ExUnit.Case, async: true

  alias Relay.Datasets.Package

  @moduletag :tmp_dir

  @schema ~s({"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "required": ["days"], "properties": {"days": {"type": "integer", "minimum": 1}}})

  defp write!(dir, files) do
    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end
  end

  describe "OP-65 (5) bundled data set versions" do
    test "OP-65: data sets are read in name order with versions in number order", %{tmp_dir: dir} do
      write!(dir, %{
        "zeta_set/schema.json" => @schema,
        "zeta_set/v1.json" => ~s({"days": 1}),
        "alpha_set/schema.json" => @schema,
        "alpha_set/v10.json" => ~s({"days": 10}),
        "alpha_set/v2.json" => ~s({"days": 2})
      })

      assert {:ok, [alpha, zeta]} = Package.read(dir)
      assert alpha.name == "alpha_set" and zeta.name == "zeta_set"
      assert Enum.map(alpha.versions, & &1.no) == [2, 10]
      assert [%{content: %{"days" => 2}, digest: <<_::256>>}, _] = alpha.versions
      assert {:ok, alpha.schema_digest} == Relay.Datasets.Schema.digest(alpha.schema)
    end

    test "OP-65: a version that does not match its schema stops the whole package", %{
      tmp_dir: dir
    } do
      write!(dir, %{"good_set/schema.json" => @schema, "good_set/v1.json" => ~s({"days": 0})})

      assert {:error, %Relay.Error{code: :invalid_content, details: %{dataset: "good_set"}}} =
               Package.read(dir)
    end

    test "OP-65: missing schemas, stray files, bad names and bad JSON are refused", %{
      tmp_dir: dir
    } do
      cases = [
        %{"no_schema/v1.json" => ~s({"days": 1})},
        %{"only_schema/schema.json" => @schema},
        %{
          "stray_set/schema.json" => @schema,
          "stray_set/v1.json" => "{}",
          "stray_set/README" => ""
        },
        %{"zero_set/schema.json" => @schema, "zero_set/v0.json" => ~s({"days": 1})},
        %{"Bad-Name/schema.json" => @schema, "Bad-Name/v1.json" => ~s({"days": 1})},
        %{"json_set/schema.json" => @schema, "json_set/v1.json" => "{days: 1"}
      ]

      for {files, n} <- Enum.with_index(cases) do
        root = Path.join(dir, "case#{n}")
        write!(root, files)
        assert {:error, %Relay.Error{code: code}} = Package.read(root)
        assert code in [:invalid_package, :invalid_content]
      end
    end

    test "OP-65: no package directory means no bundled data sets", %{tmp_dir: dir} do
      assert Package.read(Path.join(dir, "missing")) == {:ok, []}
    end

    test "CH-18: the data sets bundled with the release are valid" do
      assert {:ok, datasets} = Package.read(Package.root())
      assert Enum.all?(datasets, &(&1.versions != []))
    end
  end
end
