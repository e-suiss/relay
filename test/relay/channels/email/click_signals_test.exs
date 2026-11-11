defmodule Relay.Channels.Email.ClickSignalsTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.ClickSignals

  @sent 1_800_000_000_000
  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Safari/605.1.15"

  defp signals, do: Bundled.content("click_signals")

  defp request(overrides \\ []) do
    Map.merge(
      %{
        method: "GET",
        ip: {203, 0, 113, 9},
        user_agent: @browser,
        headers: ["accept", "host", "user-agent"],
        at_ms: @sent + 60_000
      },
      Map.new(overrides)
    )
  end

  defp history(overrides \\ []),
    do: Map.merge(%{sent_ms: @sent, delivered_ms: nil, clicks: []}, Map.new(overrides))

  describe "DS-30 DS-52 click classification" do
    test "DS-30: a browser click a minute after the send is human" do
      assert ClickSignals.classify(signals(), request(), 1, history()) == {:human, nil}
    end

    test "DS-52: a click within two seconds of the send or the delivery is likely a bot" do
      early = request(at_ms: @sent + 1_500)
      assert ClickSignals.classify(signals(), early, 1, history()) == {:likely_bot, "timing"}

      delivered = history(delivered_ms: @sent + 59_000)
      assert {:likely_bot, "timing"} = ClickSignals.classify(signals(), request(), 1, delivered)
    end

    test "DS-52: three distinct links of one message within ten seconds are a burst" do
      clicks = [{1, @sent + 55_000}, {2, @sent + 57_000}]

      assert ClickSignals.classify(signals(), request(), 3, history(clicks: clicks)) ==
               {:likely_bot, "burst"}

      assert ClickSignals.classify(signals(), request(), 2, history(clicks: clicks)) ==
               {:human, nil}

      stale = [{1, @sent + 10_000}, {2, @sent + 20_000}]
      assert {:human, nil} =
               ClickSignals.classify(signals(), request(), 3, history(clicks: stale))
    end

    test "DS-52: a published scanner block decides with its operator" do
      for {ip, operator} <- [
            {{40, 107, 3, 4}, "microsoft"},
            {{148, 163, 130, 1}, "proofpoint"},
            {{205, 139, 110, 20}, "mimecast"},
            {{209, 222, 82, 7}, "barracuda"},
            {{74, 125, 1, 1}, "google"},
            {{0, 0, 0, 0, 0, 0xFFFF, 0x286B, 0x0304}, "microsoft"},
            {{0x2A01, 0x111, 0xF400, 0, 0, 0, 0, 1}, "microsoft"}
          ] do
        assert ClickSignals.classify(signals(), request(ip: ip), 1, history()) ==
                 {:likely_bot, "scanner_ip:" <> operator}
      end
    end

    test "DS-52: a HEAD or header-less request and an automation User-Agent are likely bots" do
      assert {:likely_bot, "request_shape"} =
               ClickSignals.classify(signals(), request(method: "HEAD"), 1, history())

      assert {:likely_bot, "request_shape"} =
               ClickSignals.classify(signals(), request(headers: ["host"]), 1, history())

      assert {:likely_bot, "user_agent"} =
               ClickSignals.classify(
                 signals(),
                 request(user_agent: "python-requests/2.32"),
                 1,
                 history()
               )
    end

    test "DS-52: every scanner block row names its source and compile date" do
      for block <- signals()["ip_blocks"] do
        assert String.starts_with?(block["source"], "https://")
        assert {:ok, _date} = Date.from_iso8601(block["compiled_at"])
        assert block["cidrs"] != []
      end

      operators = Enum.map(signals()["ip_blocks"], & &1["operator"])
      assert Enum.sort(operators) == ~w(barracuda google microsoft mimecast proofpoint)
    end
  end

  describe "DS-32 machine open" do
    test "DS-32: an image proxy or a scanner open is a machine open, a reader's is not" do
      assert ClickSignals.machine_open(signals(), request()) == {false, nil}

      proxy = request(user_agent: "Mozilla/5.0 (via ggpht.com GoogleImageProxy)")
      assert ClickSignals.machine_open(signals(), proxy) == {true, "open_proxy"}

      scanner = request(ip: {40, 92, 1, 1})
      assert ClickSignals.machine_open(signals(), scanner) == {true, "scanner_ip:microsoft"}
    end
  end
end
