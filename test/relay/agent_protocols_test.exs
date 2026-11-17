defmodule Relay.AgentProtocolsTest do
  use ExUnit.Case, async: true

  alias Relay.AgentProtocols, as: Protocols

  @states ~w(open stalled resolved expired cancelled)
  @interactions ~w(response access_invitation event)
  @protocols [:a2a, :mcp_tasks, :managed_agents]

  describe "AG-46 state mapping table" do
    test "AG-46: an open question or review asks the protocols for input" do
      waitpoint = %{state: "open", kind: "question", profile: nil}

      assert Relay.Agents.protocol_state(:a2a, waitpoint) ==
               {:ok, %{rule: :state, state: "TASK_STATE_INPUT_REQUIRED"}}

      assert Relay.Agents.protocol_state(:mcp_tasks, waitpoint) ==
               {:ok, %{rule: :state, state: "input_required"}}

      assert Relay.Agents.protocol_state(:managed_agents, %{waitpoint | kind: "review"}) ==
               {:ok, %{rule: :state, state: "requires_action"}}
    end

    test "AG-46: an open invitation to the Access approval surface is AUTH_REQUIRED on A2A" do
      waitpoint = %{state: "open", kind: "review", profile: "guardian_approval"}

      assert Relay.Agents.protocol_state(:a2a, waitpoint) ==
               {:ok, %{rule: :state, state: "TASK_STATE_AUTH_REQUIRED"}}

      assert Relay.Agents.protocol_state(:mcp_tasks, waitpoint) ==
               {:ok, %{rule: :state, state: "input_required"}}
    end

    test "AG-46: a stalled waitpoint changes no protocol state and a resolved one lets the waiter go on" do
      stalled = %{state: "stalled", kind: "question", profile: nil}

      for protocol <- @protocols do
        assert Relay.Agents.protocol_state(protocol, stalled) ==
                 {:ok, %{rule: :unchanged, state: nil}}
      end

      resolved = %{state: "resolved", kind: "question", profile: nil}
      assert {:ok, %{state: "TASK_STATE_WORKING"}} = Relay.Agents.protocol_state(:a2a, resolved)
      assert {:ok, %{state: "working"}} = Relay.Agents.protocol_state(:mcp_tasks, resolved)
      assert {:ok, %{state: "running"}} = Relay.Agents.protocol_state(:managed_agents, resolved)
    end

    test "AG-46: an expired or cancelled waitpoint leaves the task to its owner" do
      for state <- ["expired", "cancelled"], protocol <- @protocols do
        waitpoint = %{state: state, kind: "review", profile: nil}

        assert Relay.Agents.protocol_state(protocol, waitpoint) ==
                 {:ok, %{rule: :owner_decides, state: nil}}
      end
    end

    test "AG-46: the translation is lossless in both directions" do
      table = Protocols.bundled()
      assert Protocols.consistent(table) == :ok

      for protocol <- @protocols, state <- @states, interaction <- @interactions do
        assert {:ok, cell} = Protocols.translate(table, protocol, state, interaction)

        if cell.rule == :state do
          assert {state, interaction} in Protocols.waitpoints(table, protocol, cell.state)
        else
          assert cell.state == nil
        end
      end

      assert Relay.Agents.protocol_waitpoints(:a2a, "TASK_STATE_AUTH_REQUIRED") ==
               [{"open", "access_invitation"}]

      assert Protocols.translate(table, :a2a, "paused", "response") == :error
    end
  end

  describe "AG-47 E-50 E-74 protocol versions are data" do
    test "E-50: Relay speaks A2A 1.0 and MCP 2026-07-28 and serves the current versions" do
      assert Relay.Agents.protocol_version("a2a") == "1.0"
      assert Relay.Agents.protocol_version("mcp") == "2026-07-28"
      assert "1.0" in Relay.Agents.protocol_versions("a2a")
      assert "2026-07-28" in Relay.Agents.protocol_versions("mcp")
      assert Protocols.version_header(Protocols.bundled(), "a2a") == "A2A-Version"
    end

    test "AG-47: a protocol revision is a new version of the table and changes no waitpoint state" do
      table = Protocols.bundled()

      revised =
        table
        |> put_in(["protocols", "a2a", "current"], "1.1")
        |> put_in(["protocols", "a2a", "served"], ["1.1", "1.0"])
        |> update_in(["states"], fn rows -> Enum.map(rows, &resubmitted/1) end)

      assert Protocols.consistent(revised) == :ok
      assert Protocols.current(revised, "a2a") == "1.1"
      assert Protocols.served?(revised, "a2a", "1.0")
      refute Protocols.served?(table, "a2a", "1.1")

      waitpoint = %{state: "resolved", kind: "question", profile: nil}

      assert {:ok, %{state: "TASK_STATE_SUBMITTED"}} = Protocols.of(revised, :a2a, waitpoint)
      assert {:ok, %{state: "TASK_STATE_WORKING"}} = Protocols.of(table, :a2a, waitpoint)

      assert Enum.map(revised["states"], & &1["waitpoint"]) ==
               Enum.map(table["states"], & &1["waitpoint"])
    end

    test "AG-47: a table with a missing row or an unserved current version is refused" do
      table = Protocols.bundled()

      broken = update_in(table, ["states"], &tl/1)
      assert {:error, %Relay.Error{}} = Protocols.consistent(broken)

      unserved = put_in(table, ["protocols", "mcp", "current"], "2027-01-01")
      assert {:error, %Relay.Error{}} = Protocols.consistent(unserved)
    end
  end

  defp resubmitted(%{"waitpoint" => "resolved"} = row),
    do: put_in(row, ["a2a", "state"], "TASK_STATE_SUBMITTED")

  defp resubmitted(row), do: row
end
