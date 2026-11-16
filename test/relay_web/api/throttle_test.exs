defmodule RelayWeb.Api.ThrottleTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @step %{"key" => "orders", "limit" => 1, "window" => "PT1H"}

  defp hit(scope, key, ref), do: Relay.Workflow.throttle_now(scope, @step, %{key: key, ref: ref})

  defp reset(scope, key, token \\ nil) do
    path = "/v1/throttles/" <> URI.encode(key, &URI.char_unreserved?/1) <> "/reset"
    F.request(:post, path, token || F.token(scope))
  end

  describe "WF-32 API-69 throttle reset" do
    test "API-69, WF-32: an active key is reset and the next event counts from zero" do
      scope = TenantFixture.tenant!().live
      key = "orders:user/42"

      assert {:ok, %{outcome: :allowed}} = hit(scope, key, "n1")
      assert {:ok, %{outcome: :limited}} = hit(scope, key, "n2")

      assert F.body(reset(scope, key), 200) == %{"object" => "throttle_reset", "key" => key}
      assert {:ok, %{outcome: :allowed, count: 1}} = hit(scope, key, "n3")
    end

    test "API-69: a key without an active window and a key of another tenant are not found" do
      scope = TenantFixture.tenant!().live
      theirs = TenantFixture.tenant!().live
      {:ok, _} = hit(theirs, "theirs", "n1")

      assert F.body(reset(scope, "unknown"), 404)["code"] == "throttle_not_found"
      assert F.body(reset(scope, "theirs"), 404)["code"] == "throttle_not_found"
      assert F.body(reset(theirs, "theirs"), 200)["object"] == "throttle_reset"
    end

    test "API-69: the reset needs the config scope" do
      scope = TenantFixture.tenant!().live
      {:ok, _} = hit(scope, "orders", "n1")

      conn = reset(scope, "orders", F.token(scope, ["read"]))
      assert conn.status == 403
    end
  end
end
