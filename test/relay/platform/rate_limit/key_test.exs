defmodule Relay.Platform.RateLimit.KeyTest do
  use ExUnit.Case, async: true

  import Mox

  alias Relay.Platform.RateLimit
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  @sms Limit.new!(
         id: "provider.sms.mps",
         algorithm: :gcra,
         unit: :segment,
         limit: 10,
         period_ms: 1_000,
         burst: 1
       )

  defp scope, do: Relay.Scope.new!(Relay.Id.generate(), :live)

  describe "CH-17 T-20 (6) limit keys" do
    test "CH-17: a limit without key parts cannot be built and a check without parts raises" do
      assert {:error, %Relay.Error{code: :invalid_limit_key}} = Limit.key(@sms, [])

      assert_raise ArgumentError, fn ->
        RateLimit.check(scope(), @sms, [], 1, :l1,
          backend: __MODULE__.Unstarted,
          adapter: ValkeyMock
        )
      end
    end

    test "T-20 (6): the key is the limit id and one to six parts; tenant and environment stay in the prefix" do
      assert {:ok, "provider.sms.mps:sms:0192f3a4:ab12"} =
               Limit.key(@sms, ["sms", "0192f3a4", "ab12"])

      assert {:error, _} = Limit.key(@sms, ~w(a b c d e f g))
      assert {:error, _} = Limit.key(@sms, ["has space"])
      assert {:error, _} = Limit.key(@sms, ["a:b"])

      scope = scope()
      tenant = Relay.Id.to_string(scope.tenant_id)
      {:ok, key} = Scripts.key(scope, ["rl", "g"], "provider.sms.mps:sms:acct")
      assert key.name == "relay:t:#{tenant}:live:rl:g:provider.sms.mps:sms:acct"
    end
  end

  describe "T-11 single clock authority" do
    test "T-11: the Valkey script gets no node time; the decision time is read inside the script" do
      expect(ValkeyMock, :command, fn ["EVALSHA", _sha, "1", _key | args] ->
        assert args == ["100000", "1", "1", "-1", "10", "1000000", "0"]
        {:ok, [0, 0, 1_700_000_000_100_000, 1_700_000_000_000_000, 1]}
      end)

      assert {:allow, %{backend: :valkey}} =
               RateLimit.check(scope(), @sms, ["sms", "acct"], 1, :l1,
                 backend: __MODULE__.Unstarted,
                 adapter: ValkeyMock
               )
    end

    test "T-20 (1): a Valkey denial is a decision with a retry and a rule, not an error" do
      expect(ValkeyMock, :command, fn ["EVALSHA" | _] -> {:ok, [1, 50_000, 0, 0, 1]} end)

      assert {:deny, 50, "rate_limit.provider.sms.mps"} =
               RateLimit.check(scope(), @sms, ["sms", "acct"], 1, :l1,
                 backend: __MODULE__.Unstarted,
                 adapter: ValkeyMock
               )
    end

    test "T-33: a ceiling denial names the lane and l0 is held only by the GCRA" do
      limit = %{@sms | burst: 10, ceiling: true}

      expect(ValkeyMock, :command, fn ["EVALSHA", _, "1", _ | args] ->
        assert Enum.at(args, 3) == "6"
        {:ok, [2, 100_000, 0, 0, 6]}
      end)

      assert {:deny, 100, "rate_limit.lane_ceiling.l3"} =
               RateLimit.check(scope(), limit, ["sms", "acct"], 1, :l3,
                 ceiling_bp: 6000,
                 backend: __MODULE__.Unstarted,
                 adapter: ValkeyMock
               )

      expect(ValkeyMock, :command, fn ["EVALSHA", _, "1", _ | args] ->
        assert Enum.at(args, 3) == "-1"
        {:ok, [0, 0, 0, 0, 1]}
      end)

      assert {:allow, _} =
               RateLimit.check(scope(), limit, ["sms", "acct"], 1, :l0,
                 backend: __MODULE__.Unstarted,
                 adapter: ValkeyMock
               )

      assert_raise ArgumentError, fn ->
        RateLimit.check(scope(), limit, ["sms", "acct"], 1, :l2,
          backend: __MODULE__.Unstarted,
          adapter: ValkeyMock
        )
      end
    end
  end

  describe "T-9 (5) stricter of two backends" do
    test "T-9: dual allows only when both allow and waits the longer denial" do
      assert RateLimit.stricter(:allow, :allow) == :allow
      assert RateLimit.stricter(:allow, {:deny, 5, "a"}) == {:deny, 5, "a"}
      assert RateLimit.stricter({:deny, 5, "a"}, :allow) == {:deny, 5, "a"}
      assert RateLimit.stricter({:deny, 5, "a"}, {:deny, 9, "b"}) == {:deny, 9, "b"}
    end
  end
end
