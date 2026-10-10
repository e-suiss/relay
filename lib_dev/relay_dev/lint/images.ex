defmodule RelayDev.Lint.Images do
  @moduledoc """
  Supply chain pinning lint. GitHub Actions are pinned by commit SHA, container images by digest, image entry points use exec form, the benchmark runner only takes scheduled or manual jobs, Renovate waits seven days, and the local environment carries the decided services. Exceptions live in `conformance/catalog/image-allow.json` with a reason.
  """

  alias RelayDev.Lint
  alias RelayDev.Lint.Violation

  @allowlist "conformance/catalog/image-allow.json"
  @compose "deploy/compose.yaml"
  @services ~w(postgres valkey mailpit apns fcm sms toxiproxy otel-collector jaeger prometheus grafana access)

  # T-78
  # T-80
  # T-5
  # T-52
  # T-79
  @doc "Returns pinning violations under `root`."
  @spec run(Path.t()) :: [Violation.t()]
  def run(root) do
    {allowed, invalid} = Lint.allowlist(root, @allowlist)

    found =
      Enum.flat_map(
        Lint.files(root, [".github/workflows/*.{yml,yaml}", ".github/actions/**/*.{yml,yaml}"]),
        &workflow(root, &1)
      ) ++
        Enum.flat_map(Lint.files(root, ["**/Dockerfile*"]), &dockerfile(root, &1)) ++
        Enum.flat_map(compose_files(root), &compose_images(root, &1)) ++
        compose_services(root) ++ renovate(root)

    invalid ++ Enum.reject(found, &Lint.allowed?(allowed, &1))
  end

  defp workflow(root, path) do
    content = File.read!(Path.join(root, path))

    pins =
      Lint.scan_lines(path, content, [
        {"action_sha",
         ~r/^\s*(-\s+)?uses:\s+(?!\.\/)(?!docker:\/\/)[^@\s]+@(?![0-9a-f]{40}(\s|$))/,
         "action must be pinned by a 40-character commit SHA"},
        {"image_digest", ~r/^\s*(-\s+)?uses:\s+docker:\/\/(?!.*@sha256:[0-9a-f]{64})/,
         "docker action must be pinned by digest"},
        {"image_digest", ~r/^\s*image:\s+(?!.*\$\{\{)(?!.*@sha256:[0-9a-f]{64})\S+/,
         "service image must be pinned by digest"}
      ])

    pins ++ bench_triggers(path, content)
  end

  defp bench_triggers(path, content) do
    if content =~ ~r/runs-on:.*\bbench\b/ and
         content =~ ~r/^\s*(pull_request|pull_request_target|push|workflow_run)\s*:/m do
      [
        %Violation{
          path: path,
          line: 0,
          rule: "bench_trigger",
          message: "the bench runner only takes schedule and workflow_dispatch jobs"
        }
      ]
    else
      []
    end
  end

  defp dockerfile(root, path) do
    content = File.read!(Path.join(root, path))

    from =
      Lint.scan_lines(path, content, [
        {"image_digest", ~r/^FROM\s+(?!scratch\b)(?!\S*@sha256:[0-9a-f]{64})\S+/i,
         "base image must be pinned by digest"}
      ])

    entry =
      Lint.scan_lines(path, content, [
        {"exec_form", ~r/^(ENTRYPOINT|CMD)\s+(?!\[)/, "entry point must use exec form (T-5)"}
      ])

    from ++ entry
  end

  defp compose_files(root) do
    root |> Lint.files(["deploy/**/*.{yml,yaml}"]) |> Enum.reject(&String.contains?(&1, "/helm/"))
  end

  defp compose_images(root, path) do
    Lint.scan_lines(path, File.read!(Path.join(root, path)), [
      {"image_digest", ~r/^\s*image:\s+(?!\S*@sha256:[0-9a-f]{64})\S+/,
       "image must be pinned by digest"}
    ])
  end

  defp compose_services(root) do
    case File.read(Path.join(root, @compose)) do
      {:ok, content} ->
        present = for [_, name] <- Regex.scan(~r/^  ([a-z][a-z0-9-]*):\s*$/m, content), do: name

        for service <- @services, service not in present do
          %Violation{
            path: @compose,
            line: 0,
            rule: "compose_services",
            message: "missing local service #{service} (T-52, T-65, T-79)"
          }
        end

      {:error, :enoent} ->
        [
          %Violation{
            path: @compose,
            line: 0,
            rule: "compose_services",
            message: "local environment is missing"
          }
        ]
    end
  end

  defp renovate(root) do
    case Lint.read_json(root, "renovate.json", nil) do
      %{"minimumReleaseAge" => "7 days"} ->
        []

      _ ->
        [
          %Violation{
            path: "renovate.json",
            line: 0,
            rule: "renovate",
            message: "renovate.json must set minimumReleaseAge to \"7 days\""
          }
        ]
    end
  end
end
