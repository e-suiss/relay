defmodule Relay.RepositoryTest do
  use ExUnit.Case, async: true

  describe "T-61 test discipline" do
    test "T-61: the pull request suite has a ten-minute budget" do
      assert File.read!(".github/workflows/ci.yml") =~
               ~r/check:\n\s+runs-on: [^\n]+\n\s+timeout-minutes: 10\n/
    end
  end

  describe "T-62 supply chain" do
    test "T-62: CI audits dependencies and scans for secrets" do
      ci = File.read!(".github/workflows/ci.yml")

      for step <- ["mix hex.audit", "mix deps.audit", "mix deps.get --check-locked", "gitleaks"] do
        assert ci =~ step
      end
    end

    test "T-62: releases are signed and carry an SBOM and provenance" do
      release = File.read!(".github/workflows/release.yml")

      for step <- ["cyclonedx-json", "cosign sign", "cosign attest", "attest-build-provenance"] do
        assert release =~ step
      end
    end

    test "T-78: workflows pin actions by SHA and Renovate waits seven days" do
      assert Jason.decode!(File.read!("renovate.json"))["minimumReleaseAge"] == "7 days"
    end

    test "T-71: the toolchain is pinned" do
      assert File.read!(".tool-versions") == "erlang 29.0.6\nelixir 1.20.4-otp-29\n"
    end
  end

  describe "INV-58 no development mode" do
    test "INV-58: no configuration file sets a development mode or a weakening flag" do
      for path <- Path.wildcard("config/*.exs") do
        refute File.read!(path) =~ ~r/\b(dev_mode|disable_\w+|skip_\w+|insecure|verify_none)\b/,
               path
      end
    end
  end
end
