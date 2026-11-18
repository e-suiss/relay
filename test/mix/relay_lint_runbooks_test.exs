defmodule RelayDev.Lint.RunbooksTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Runbooks

  @moduletag :tmp_dir

  @today ~D[2026-11-18]

  @command ~s(kubectl patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}')

  @front %{
    "id" => "disk-full",
    "kind" => "alert",
    "severity" => "SEV3",
    "channels" => "[all]",
    "tenant_scope" => "all",
    "alerts" => "[RelayDiskFull]",
    "last_tested" => "2026-11-01",
    "tested_by" => "game_day",
    "automation" => "2",
    "eta_minutes" => "15",
    "reversible" => "true"
  }

  @sections """
  ## Symptom

  The disk fills.

  ## Impact

  Writes stop.

  ## Diagnosis

  ```sh
  df -h /var/lib/postgresql
  ```

  ## Decision tree

  ```text
  disk > 90%
  └── grow the volume
  ```

  ## Mitigation

  ```sh state-changing
  kubectl patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
  ```

  ## Fix and escalation

  Unknown.
  """

  defp runbook(changes \\ %{}, sections \\ @sections) do
    front = Map.merge(@front, changes)

    fields = for {key, value} <- front, value != nil, do: "#{key}: #{value}\n"

    "---\n#{fields}---\n\n# Disk full\n\n#{sections}"
  end

  defp alerts(url \\ "runbooks/disk-full.md") do
    """
    groups:
      - name: test
        rules:
          - alert: RelayDiskFull
            expr: up == 0
            annotations:
              runbook_url: #{url}
    """
  end

  defp run(dir, files) do
    write!(dir, Map.put_new(files, "deploy/observability/alerts.yaml", alerts()))
    dir |> Runbooks.run(today: @today) |> rules() |> Enum.sort()
  end

  describe "OP-43 runbook format" do
    test "OP-43: a complete runbook linked from its alert passes", %{tmp_dir: dir} do
      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(),
               "runbooks/README.md" => "# Runbooks\n"
             }) == []
    end

    test "OP-43: a missing or empty section fails", %{tmp_dir: dir} do
      missing = String.replace(@sections, "## Impact\n\nWrites stop.\n\n", "")
      empty = String.replace(@sections, "Writes stop.\n", "")

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{}, missing)}) == ["section"]
      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{}, empty)}) == ["section"]
    end

    test "OP-43: a heading inside a code block is not a section", %{tmp_dir: dir} do
      shifted = String.replace(@sections, "## Impact\n", "```text\n## Impact\n```\n")
      assert "section" in run(dir, %{"runbooks/disk-full.md" => runbook(%{}, shifted)})
    end

    test "OP-43: missing and invalid front matter fields fail", %{tmp_dir: dir} do
      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{"eta_minutes" => nil})}) ==
               ["front-matter"]

      for {field, value} <- [
            {"severity", "P1"},
            {"tenant_scope", "everyone"},
            {"channels", "[pager]"},
            {"tested_by", "review"},
            {"automation", "0"},
            {"eta_minutes", "soon"},
            {"reversible", "maybe"},
            {"last_tested", "yesterday"},
            {"id", "disk"}
          ] do
        result = run(dir, %{"runbooks/disk-full.md" => runbook(%{field => value})})
        assert result == ["front-matter"], field
      end

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{"kind" => "playbook"})}) ==
               ["front-matter", "kind"]
    end

    test "OP-43: a file without front matter fails", %{tmp_dir: dir} do
      assert "front-matter" in run(dir, %{"runbooks/disk-full.md" => "# Disk full\n"})
    end

    test "OP-43: a runbook last tested more than 183 days ago is unreliable", %{tmp_dir: dir} do
      stale = Date.to_iso8601(Date.add(@today, -184))
      fresh = Date.to_iso8601(Date.add(@today, -183))

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{"last_tested" => stale})}) ==
               ["stale"]

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{"last_tested" => fresh})}) == []
    end

    test "OP-43: a state-changing block holds one command", %{tmp_dir: dir} do
      for body <- [
            "kubectl scale deploy/relay --replicas=4\nkubectl rollout status deploy/relay",
            "kubectl scale deploy/relay --replicas=4 && kubectl rollout status deploy/relay",
            "kubectl scale deploy/relay --replicas=4; echo done"
          ] do
        sections = String.replace(@sections, @command, body)

        result = run(dir, %{"runbooks/disk-full.md" => runbook(%{}, sections)})
        assert result == ["state-changing"], body
      end

      continued =
        String.replace(
          @sections,
          ~s(kubectl patch pvc data -p),
          "psql \"$PG_ADMIN_URL\" \\\n  -c \"SELECT 1; SELECT 2\" &&\\\n"
        )

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{}, continued)}) ==
               ["state-changing"]

      quoted =
        String.replace(
          @sections,
          @command,
          "psql \"$PG_ADMIN_URL\" \\\n  -c \"SELECT pg_cancel_backend(1); -- && ||\""
        )

      assert run(dir, %{"runbooks/disk-full.md" => runbook(%{}, quoted)}) == []
    end

    test "OP-43: an unclosed code block fails", %{tmp_dir: dir} do
      sections = @sections <> "\n```sh\nls\n"
      assert "fence" in run(dir, %{"runbooks/disk-full.md" => runbook(%{}, sections)})
    end
  end

  describe "OP-37 (6) alert links" do
    test "OP-37: an alert without runbook_url or pointing at a missing file fails", %{
      tmp_dir: dir
    } do
      no_url = String.replace(alerts(), ~r/\s+annotations:\n.*\n/, "\n")

      assert "runbook_url" in run(dir, %{
               "deploy/observability/alerts.yaml" => no_url,
               "runbooks/disk-full.md" => runbook(%{"kind" => "procedure", "alerts" => "[]"})
             })

      assert run(dir, %{
               "deploy/observability/alerts.yaml" => alerts("runbooks/disk.md"),
               "runbooks/disk-full.md" => runbook(%{"kind" => "procedure", "alerts" => "[]"})
             }) == ["runbook_url"]

      assert run(dir, %{
               "deploy/observability/alerts.yaml" =>
                 alerts("https://example.com/runbooks.md#relaydiskfull"),
               "runbooks/disk-full.md" => runbook(%{"kind" => "procedure", "alerts" => "[]"})
             }) == ["runbook_url"]
    end

    test "OP-37: the repository URL form of runbook_url is accepted", %{tmp_dir: dir} do
      url = "https://github.com/e-suiss/relay/blob/main/runbooks/disk-full.md"

      assert run(dir, %{
               "deploy/observability/alerts.yaml" => alerts(url),
               "runbooks/disk-full.md" => runbook()
             }) == []
    end

    test "OP-43: an alert runbook no alert points to fails unless it is a procedure", %{
      tmp_dir: dir
    } do
      other = String.replace(runbook(), "disk-full", "disk-slow")

      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(),
               "runbooks/disk-slow.md" => other
             }) == ["alerts"]

      procedure = runbook(%{"id" => "disk-slow", "kind" => "procedure", "alerts" => "[]"})

      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(),
               "runbooks/disk-slow.md" => procedure
             }) == []
    end

    test "OP-43: the alerts listed in front matter match the alerts that point here", %{
      tmp_dir: dir
    } do
      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(%{"alerts" => "[RelayDiskFull, RelayDiskGone]"})
             }) == ["alerts"]

      assert "kind" in run(dir, %{
               "runbooks/disk-full.md" => runbook(%{"kind" => "procedure", "alerts" => "[]"})
             })
    end
  end

  describe "OP-46 incident documents" do
    test "OP-46: an incident document needs its front matter and no empty section", %{
      tmp_dir: dir
    } do
      doc = fn body ->
        "---\nid: roles\nkind: incident\nlast_tested: 2026-11-18\ntested_by: none\n---\n\n#{body}"
      end

      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(),
               "runbooks/incident/roles.md" => doc.("# Roles\n\n## Commander\n\nLeads.\n")
             }) == []

      assert run(dir, %{
               "runbooks/disk-full.md" => runbook(),
               "runbooks/incident/roles.md" => doc.("# Roles\n\n## Commander\n\n## Scribe\n\nx\n")
             }) == ["section"]
    end
  end
end
