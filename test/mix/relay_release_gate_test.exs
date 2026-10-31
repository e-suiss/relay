defmodule RelayDev.ReleaseTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Release

  @moduletag :tmp_dir

  @dir "priv/datasets/retention_periods"

  defp period(class, basis) do
    %{
      "region" => "tr",
      "sector" => "general",
      "retention_class" => class,
      "days" => 730,
      "legal_basis" => basis,
      "source" => "test"
    }
  end

  defp version(periods), do: Jason.encode!(%{"source_ref" => "test", "periods" => periods})

  describe "OP-72 (1) F-33 legal approval release gate" do
    test "OP-72: a row of the newest version awaiting legal approval stops the release", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "#{@dir}/schema.json" => "{}",
        "#{@dir}/v1.json" => version([period("audit", "6698 m.12")]),
        "#{@dir}/v2.json" =>
          version([
            period("audit", "6698 m.12"),
            period("delivery_record", "pending legal approval (OP-71.7)")
          ])
      })

      assert [violation] = Release.gate(dir)
      assert violation.rule == "legal_approval"
      assert violation.path == "#{@dir}/v2.json"
      assert violation.message =~ "tr/general/delivery_record"
    end

    test "OP-72: a pending row only in an older version does not stop the release", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "#{@dir}/v2.json" => version([period("delivery_record", "pending legal approval")]),
        "#{@dir}/v10.json" => version([period("delivery_record", "6563 m.11(3)")])
      })

      assert Release.gate(dir) == []
    end

    test "OP-72: a legal basis mentioning pending approval outside the marker form stops the release",
         %{tmp_dir: dir} do
      write!(dir, %{
        "#{@dir}/v1.json" =>
          version([
            period("audit", "Pending legal approval"),
            period("traffic", "approval pending")
          ])
      })

      assert rules(Release.gate(dir)) == ["legal_approval", "legal_approval"]
      assert Enum.all?(Release.gate(dir), &(&1.message =~ "without the marker"))
    end

    test "OP-72: a missing or unreadable version stops the release", %{tmp_dir: dir} do
      assert [%{message: "no retention_periods version is bundled"}] = Release.gate(dir)

      write!(dir, %{"#{@dir}/v1.json" => "{"})
      assert [%{message: "not a readable retention_periods version"}] = Release.gate(dir)
    end

    test "OP-72: the pending marker is one exact form" do
      assert Release.pending_legal_approval() == "pending legal approval"
      assert Release.pending_legal_approval?("pending legal approval")
      assert Release.pending_legal_approval?("pending legal approval (OP-71.7)")
      refute Release.pending_legal_approval?("pending legal approval ()")
      refute Release.pending_legal_approval?("pending legal approval (OP-71.7")
      refute Release.pending_legal_approval?("Pending legal approval")
      refute Release.pending_legal_approval?("6698 m.12")
      refute Release.pending_legal_approval?(nil)
    end

    test "OP-72: normal CI never runs the release gate" do
      tasks = Mix.Project.config()[:aliases] |> Keyword.values() |> List.flatten()
      refute Enum.any?(tasks, &(is_binary(&1) and &1 =~ "relay.release.gate"))

      for workflow <- Path.wildcard(".github/workflows/*.yml") do
        mentions? = File.read!(workflow) =~ "relay.release.gate"
        assert mentions? == (Path.basename(workflow) == "release.yml"), workflow
      end
    end
  end

  describe "TN-71 suspension periods await legal approval" do
    test "TN-71: a suspension policy awaiting legal approval stops the release", %{tmp_dir: dir} do
      policy = "priv/datasets/suspension_policy"
      basis = fn text -> Jason.encode!(%{"legal_basis" => text, "notice_days" => 7}) end

      write!(dir, %{
        "#{@dir}/schema.json" => "{}",
        "#{@dir}/v1.json" => version([period("audit", "6698 m.12")]),
        "#{policy}/schema.json" => "{}",
        "#{policy}/v1.json" => basis.("pending legal approval (TN-71)")
      })

      assert [violation] = Release.gate(dir)
      assert violation.path == policy <> "/v1.json"
      assert violation.rule == "legal_approval"

      write!(dir, %{"#{policy}/v2.json" => basis.("approved 2026-12-01")})
      assert Release.gate(dir) == []
    end

    test "TN-71: the bundled suspension policy carries the approved values and awaits legal approval" do
      content =
        "priv/datasets/suspension_policy/v1.json" |> File.read!() |> Jason.decode!()

      assert %{"notice_days" => 7, "immediate_notice_hours" => 24, "appeal_days" => 14} = content
      assert Release.pending_legal_approval?(content["legal_basis"])
    end
  end
end
