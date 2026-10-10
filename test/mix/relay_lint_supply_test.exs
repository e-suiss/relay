defmodule RelayDev.Lint.SupplyTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.{Deps, Nif}

  describe "T-51 T-62 INV-57 licenses" do
    test "T-62: every dependency of this project carries a permissive license" do
      assert Deps.run(File.cwd!()) == []
    end

    @tag :tmp_dir
    test "T-51: a copyleft dependency or an excluded framework is rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "mix.lock" => """
        %{
          "gpl_pkg": {:hex, :gpl_pkg, "1.0.0", "00", [:mix], [], "hexpm", "00"},
          "ash": {:hex, :ash, "3.0.0", "00", [:mix], [], "hexpm", "00"},
        }
        """,
        "deps/gpl_pkg/hex_metadata.config" => ~s({<<"licenses">>,[<<"GPL-3.0">>]}.\n),
        "deps/ash/hex_metadata.config" => ~s({<<"licenses">>,[<<"MIT">>]}.\n)
      })

      assert Enum.sort(rules(Deps.run(dir))) == ["forbidden_framework", "license"]
    end

    test "INV-57: Relay ships under one license with no edition or license flag" do
      assert Mix.Project.config()[:package][:licenses] == ["Apache-2.0"]
      assert File.read!("LICENSE") =~ "Apache License"
      assert File.read!("LICENSE") =~ "Version 2.0"

      for path <- Path.wildcard("{config,lib}/**/*.{ex,exs}") do
        refute File.read!(path) =~
                 ~r/\b(edition|enterprise|license_key|cloud_only|feature_flag)\b/i,
               path
      end
    end
  end

  describe "T-53 native code" do
    @describetag :tmp_dir

    test "T-53: a NIF crate outside the allowed list is rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "native/fast_json/Cargo.toml" =>
          "[package]\nname = \"fast_json\"\n[dependencies]\nrustler = \"0.37\"\n",
        "native/mjml/Cargo.toml" =>
          "[package]\nname = \"mjml\"\n[dependencies]\nrustler = \"0.37\"\n",
        "conformance/catalog/native.json" =>
          ~s({"nif": [{"crate": "mjml", "rule": "T-53"}], "port": []})
      })

      assert [%{path: "native/fast_json/Cargo.toml"}] = Nif.run(dir)
    end

    test "T-53: a Port program on the port list passes", %{tmp_dir: dir} do
      write!(dir, %{
        "native/pkcs11_port/Cargo.toml" => "[package]\nname = \"pkcs11_port\"\n",
        "conformance/catalog/native.json" =>
          ~s({"nif": [], "port": [{"crate": "pkcs11_port", "rule": "TN-63"}]})
      })

      assert Nif.run(dir) == []
    end
  end
end
