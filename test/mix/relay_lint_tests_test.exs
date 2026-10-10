defmodule RelayDev.Lint.TestsTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Tests

  @moduletag :tmp_dir

  describe "T-61 flaky tests" do
    test "T-61: a quarantine without an issue and a retry option are rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "test/a_test.exs" => "@tag :quarantine\ntest \"x\" do\nend\n@moduletag retries: 3\n"
      })

      assert Enum.sort(rules(Tests.run(dir))) == ["quarantine", "retry"]
    end

    test "T-61: a quarantine with an issue passes, but blocks a release", %{tmp_dir: dir} do
      write!(dir, %{"test/a_test.exs" => "@tag quarantine: \"#42\"\ntest \"x\" do\nend\n"})
      assert Tests.run(dir) == []
      assert rules(Tests.run(dir, release: true)) == ["quarantine"]
    end
  end
end
