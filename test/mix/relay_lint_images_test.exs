defmodule RelayDev.Lint.ImagesTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Images

  @moduletag :tmp_dir

  @sha "3d3c42e5aac5ba805825da76410c181273ba90b1"
  @digest "sha256:" <> String.duplicate("a", 64)
  @services ~w(postgres valkey mailpit apns fcm sms toxiproxy otel-collector jaeger prometheus grafana access)

  defp compose(services) do
    "services:\n" <> Enum.map_join(services, "", &"  #{&1}:\n    image: x/#{&1}:1@#{@digest}\n")
  end

  defp baseline(dir, extra \\ %{}) do
    write!(
      dir,
      Map.merge(
        %{
          "deploy/compose.yaml" => compose(@services),
          "renovate.json" => ~s({"minimumReleaseAge": "7 days"}),
          ".github/workflows/ci.yml" =>
            "on:\n  push:\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@#{@sha} # v7.0.1\n",
          "deploy/docker/Dockerfile" =>
            "FROM debian:13@#{@digest}\nENTRYPOINT [\"/app/bin/relay\"]\n"
        },
        extra
      )
    )
  end

  describe "T-78 pinning" do
    test "T-78: a pinned repository passes", %{tmp_dir: dir} do
      baseline(dir)
      assert Images.run(dir) == []
    end

    test "T-78: actions referenced by tag and images referenced without digest are rejected", %{
      tmp_dir: dir
    } do
      baseline(dir, %{
        ".github/workflows/ci.yml" =>
          "jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n",
        "deploy/docker/Dockerfile" => "FROM debian:13\nENTRYPOINT [\"/app/bin/relay\"]\n",
        "deploy/compose.yaml" => compose(@services) <> "  extra:\n    image: postgres:18\n"
      })

      assert Enum.sort(rules(Images.run(dir))) == ["action_sha", "image_digest", "image_digest"]
    end

    test "T-78: Renovate must wait seven days", %{tmp_dir: dir} do
      baseline(dir, %{"renovate.json" => ~s({"minimumReleaseAge": "1 day"})})
      assert rules(Images.run(dir)) == ["renovate"]
    end
  end

  describe "T-80 T-5 T-52 T-79 X-40" do
    test "T-80: the bench runner refuses pull request and push triggers", %{tmp_dir: dir} do
      baseline(dir, %{
        ".github/workflows/bench.yml" =>
          "on:\n  pull_request:\njobs:\n  b:\n    runs-on: [self-hosted, bench]\n"
      })

      assert rules(Images.run(dir)) == ["bench_trigger"]
    end

    test "T-5: image entry points use exec form", %{tmp_dir: dir} do
      baseline(dir, %{
        "deploy/docker/Dockerfile" =>
          "FROM debian:13@#{@digest}\nENTRYPOINT /app/bin/relay start\n"
      })

      assert rules(Images.run(dir)) == ["exec_form"]
    end

    test "T-79: the local environment carries every decided service", %{tmp_dir: dir} do
      baseline(dir, %{"deploy/compose.yaml" => compose(@services -- ["jaeger", "grafana"])})
      assert rules(Images.run(dir)) == ["compose_services", "compose_services"]
    end

    test "X-40: the repository's own local environment and workflows pass" do
      assert Images.run(File.cwd!()) == []
      ci = File.read!(".github/workflows/ci.yml")
      assert ci =~ "docker compose -f deploy/compose.yaml up -d --wait postgres valkey"
    end
  end
end
