defmodule Relay.Platform.Valkey.ScriptTest do
  use ExUnit.Case, async: true

  import Mox

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  @writes ~w(SET SETEX PSETEX INCR INCRBY DECR DECRBY HSET HINCRBY ZADD ZINCRBY SADD LPUSH RPUSH)
  @source """
  local t = redis.call('TIME')
  redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
  return {1, tonumber(t[1])}
  """

  defp script, do: Script.new("probe", @source)

  defp key do
    {:ok, key} = Key.new("tnt_1", "live", ["rl", "probe"], 2_000)
    key
  end

  describe "T-9 scripts" do
    test "T-9: the SHA1 of every script under priv/valkey is the golden list" do
      lines = Enum.map(Script.all(), &"#{&1.sha}  #{&1.name}.lua\n")
      Relay.Golden.assert_golden("valkey_scripts.txt", lines)
    end

    test "T-9: every script touches only KEYS[1], reads time only through TIME and expires what it writes" do
      for script <- Script.all() do
        refute script.source =~ ~r/KEYS\[(?!1\])/, script.name
        refute script.source =~ ~r/\bos\.(time|clock|date)\b/, script.name
        refute script.source =~ ~r/redis\.call\(\s*'(SCAN|KEYS)'/i, script.name

        writes? =
          Enum.any?(@writes, &(script.source =~ ~r/redis\.call\(\s*['"]#{&1}['"]/i))

        if writes?,
          do: assert(script.source =~ ~r/PEXPIRE|'PX'|"PX"/, "#{script.name} writes without TTL")
      end
    end

    test "T-9: the SHA1 is the one SCRIPT LOAD returns for the source" do
      assert Script.sha("return 1") == "e0e1f9fabfc9d4800c877a703b823ac0578ff8db"
      assert script().sha == Script.sha(@source)
    end

    test "T-9: script names are lowercase words" do
      assert_raise ArgumentError, fn -> Script.path("../x") end
      assert Script.path("gcra") == Path.join(Script.dir(), "gcra.lua")
    end
  end

  describe "T-9 running a script" do
    test "T-9: a script runs with EVALSHA on its one key and integer arguments become text" do
      sha = script().sha

      expect(ValkeyMock, :command, fn [
                                        "EVALSHA",
                                        ^sha,
                                        "1",
                                        "relay:t:tnt_1:live:rl:probe",
                                        "v",
                                        "2000"
                                      ] ->
        {:ok, [1, 1_700_000_000]}
      end)

      assert {:ok, [1, 1_700_000_000]} = Valkey.eval(script(), key(), ["v", 2_000], ValkeyMock)
    end

    test "T-9: NOSCRIPT sends the source once with EVAL" do
      expect(ValkeyMock, :command, fn ["EVALSHA" | _] ->
        {:error, %Redix.Error{message: "NOSCRIPT No matching script. Please use EVAL."}}
      end)

      expect(ValkeyMock, :command, fn ["EVAL", @source, "1", "relay:t:tnt_1:live:rl:probe", "v"] ->
        {:ok, [1, 5]}
      end)

      assert {:ok, [1, 5]} = Valkey.eval(script(), key(), ["v"], ValkeyMock)
    end

    test "T-9: a reply that is not an array of integers is a typed error" do
      expect(ValkeyMock, :command, fn ["EVALSHA" | _] -> {:ok, ["x"]} end)

      assert {:error, %Relay.Error{code: :valkey_reply}} =
               Valkey.eval(script(), key(), [], ValkeyMock)

      expect(ValkeyMock, :command, fn ["EVALSHA" | _] ->
        {:error, %Redix.ConnectionError{reason: :closed}}
      end)

      assert {:error, %Relay.Error{code: :valkey_unavailable}} =
               Valkey.eval(script(), key(), [], ValkeyMock)
    end

    test "T-9: SCRIPT LOAD accepts only the expected SHA1s" do
      sha = script().sha
      expect(ValkeyMock, :pipeline, fn [["SCRIPT", "LOAD", @source]] -> {:ok, [sha]} end)
      assert :ok = Valkey.load([script()], ValkeyMock)

      expect(ValkeyMock, :pipeline, fn _ -> {:ok, ["0000"]} end)

      assert {:error, %Relay.Error{code: :valkey_reply}} =
               Valkey.load([script()], ValkeyMock)

      assert :ok = Valkey.load([], ValkeyMock)
    end

    test "T-9: PING succeeds only on PONG" do
      expect(ValkeyMock, :command, fn ["PING"] -> {:ok, "PONG"} end)
      assert :ok = Valkey.ping(ValkeyMock)

      expect(ValkeyMock, :command, fn ["PING"] ->
        {:error, %Redix.ConnectionError{reason: :closed}}
      end)

      assert {:error, %Relay.Error{code: :valkey_unavailable}} = Valkey.ping(ValkeyMock)
    end
  end
end
