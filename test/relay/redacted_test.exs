defmodule Relay.RedactedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Relay.Redacted

  @secret "sk_live_do_not_leak"

  describe "T-46 T-58 secrets never show" do
    test "T-58: inspect hides the value" do
      refute inspect(Redacted.wrap(@secret)) =~ @secret
      refute inspect(%{token: Redacted.wrap(@secret)}) =~ @secret
    end

    test "T-58: JSON encoding hides the value" do
      refute Jason.encode!(%{token: Redacted.wrap(@secret)}) =~ @secret
    end

    test "T-58: string interpolation is refused" do
      assert String.Chars.impl_for(Redacted.wrap(@secret)) == nil
    end

    test "T-46: logger metadata and messages do not leak the value" do
      log =
        capture_log([metadata: :all], fn ->
          require Logger

          Logger.error("provider failed: #{inspect(Redacted.wrap(@secret))}",
            token: Redacted.wrap(@secret)
          )
        end)

      refute log =~ @secret
    end

    test "T-58: reading the value is an explicit call" do
      assert Redacted.expose(Redacted.wrap(@secret)) == @secret
      assert Redacted.wrap(Redacted.wrap(@secret)) == Redacted.wrap(@secret)
    end
  end
end
