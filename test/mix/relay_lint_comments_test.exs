defmodule RelayDev.Lint.CommentsTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Comments

  @moduletag :tmp_dir

  describe "T-73 no explanatory comments" do
    test "T-73: explanatory comments are rejected in Elixir, YAML, Dockerfiles and Rust", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "lib/relay/a.ex" => "defmodule A do\n  # Explain why we do this\n  def a, do: :ok\nend\n",
        "deploy/x.yaml" => "a: 1 # because of reasons\n# setting b\nb: 2\n",
        "deploy/docker/Dockerfile" => "# build stage\nFROM scratch\n",
        "native/x/src/lib.rs" => "// does the thing\nfn a() {}\n"
      })

      assert length(Comments.run(dir)) == 5
    end

    test "T-73: spec IDs, directives, TODO(#n), shebangs, Rust docs and action notes are allowed",
         %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/a.ex" => """
        defmodule A do
          # INV-12
          # T-57 (6, 7), Access OP-94
          # credo:disable-for-next-line
          # TODO(#42): split this
          def a, do: "# not a comment"
        end
        """,
        ".github/workflows/ci.yml" =>
          "steps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
        "rel/env.sh.eex" => "#!/bin/sh\n# T-13\nexport A=1\n",
        "native/x/src/lib.rs" =>
          "//! Crate doc.\n/// Item doc.\n// SAFETY: pointer is valid\n// TN-63\nfn a() {}\n",
        "cliff.toml" => "body = \"\"\"\n### heading\n\"\"\"\n"
      })

      assert Comments.run(dir) == []
    end
  end
end
