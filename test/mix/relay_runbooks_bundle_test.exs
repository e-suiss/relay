defmodule RelayDev.RunbookBundleTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.RunbookBundle

  @moduletag :tmp_dir

  describe "OP-43 offline copy" do
    test "OP-43: every runbook is one section of one self-contained page", %{tmp_dir: dir} do
      write!(dir, %{
        "runbooks/README.md" => "# Relay runbooks\n\nSee [incident](incident/).\n",
        "runbooks/disk-full.md" => """
        ---
        id: disk-full
        kind: alert
        ---

        # Disk full

        ## Mitigation

        Follow [the severity table](incident/severity.md) and run `df -h`:

        ```sh state-changing
        kubectl scale deploy/relay-all --replicas=0 <now>
        ```

        | Step | Who |
        |---|---|
        | **Grow** the volume | ops |

        - [ ] Checked
        - Second
          continued
        """,
        "runbooks/incident/severity.md" => "# Severity\n\nBack to [disk](../disk-full.md).\n",
        "runbooks/incident/README.md" => "# Incident response\n"
      })

      html = RunbookBundle.build(dir, "v1.2.3")

      assert html =~ ~s(<title>Relay runbooks v1.2.3</title>)
      assert html =~ ~s(<article id="disk-full">)
      assert html =~ ~s(<article id="incident-severity">)
      assert html =~ ~s(<a href="#incident-severity">the severity table</a>)
      assert html =~ ~s(<a href="#disk-full">disk</a>)
      assert html =~ ~s(<a href="#incident-readme">incident</a>)
      assert html =~ ~s(<pre class="state-changing"><code>kubectl scale deploy/relay-all)
      assert html =~ "--replicas=0 &lt;now&gt;</code></pre>"
      assert html =~ "<td><strong>Grow</strong> the volume</td>"
      assert html =~ "<li>☐ Checked</li>"
      assert html =~ "<li>Second continued</li>"
      assert html =~ "<code>df -h</code>"
      assert html =~ ~s(<tr><th>kind</th><td>alert</td></tr>)
      refute html =~ "<script"
      refute html =~ ~r/(src|href)="https?:/

      assert Regex.scan(~r/<article id="([^"]+)">/, html, capture: :all_but_first) ==
               [["readme"], ["disk-full"], ["incident-readme"], ["incident-severity"]]
    end
  end
end
