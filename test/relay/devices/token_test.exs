defmodule Relay.Devices.TokenTest do
  use ExUnit.Case, async: true

  alias Relay.Devices.Token

  @keys %{"p256dh" => "p", "auth" => "a"}

  defp body(overrides) do
    base = %{"platform" => "fcm", "token" => "fcm:abc", "app" => "app", "permission" => "granted"}
    Map.merge(base, overrides)
  end

  defp pointers({:error, %Relay.Error{code: :validation_failed, details: %{errors: errors}}}),
    do: Enum.map(errors, &{&1.pointer, &1.code})

  describe "CH-28 CH-29 permission" do
    test "CH-28: only a granted device may receive any class" do
      for class <- [:security, :transactional, :marketing, nil],
          do: assert(Token.permitted?("granted", class))

      for permission <- ["denied", "not_determined"],
          class <- [:security, :marketing, nil],
          do: refute(Token.permitted?(permission, class))
    end

    test "CH-29, CH-79: a provisional device receives only marketing and social messages" do
      assert Token.permitted?("provisional", :marketing)
      assert Token.permitted?("provisional", "social")

      for class <- ~w(security transactional action_required operational system)a,
          do: refute(Token.permitted?("provisional", class))

      refute Token.permitted?("provisional", nil)
    end

    test "CH-79: a device is stale after 30 days and disabled after 270 days without a sighting" do
      assert Relay.Limits.seconds!(["devices", "stale_after"]) == 30 * 86_400
      assert Relay.Limits.seconds!(["devices", "inactive_disable_after"]) == 270 * 86_400
    end
  end

  describe "C-23 API-67 registration rules" do
    test "C-23: a platform serves push or web_push" do
      assert Token.channel("web_push") == :web_push
      for platform <- ~w(apns fcm hms unified_push), do: assert(Token.channel(platform) == :push)
      assert Token.platforms(:web_push) == ["web_push"]
      assert Enum.sort(Token.platforms(:push)) == ~w(apns fcm hms unified_push)
      assert Token.platforms(:email) == []
    end

    test "API-67: an APNs token is hex, stored lowercase and needs its environment" do
      hex = String.duplicate("AB", 32)
      apns = body(%{"platform" => "apns", "token" => hex, "apns_environment" => "sandbox"})

      assert {:ok, %{token: token}} = Token.registration(apns)
      assert token == String.downcase(hex)
      assert Token.lookup(hex) == token

      assert pointers(Token.registration(Map.delete(apns, "apns_environment"))) ==
               [{"/apns_environment", "required"}]

      assert pointers(Token.registration(Map.put(apns, "token", "not hex"))) ==
               [{"/token", "invalid_format"}]

      assert pointers(Token.registration(body(%{"apns_environment" => "production"}))) ==
               [{"/apns_environment", "not_allowed"}]
    end

    test "API-67: a Web Push token is the https endpoint and travels with its keys" do
      endpoint = "https://push.example.com/send/abc"
      web = body(%{"platform" => "web_push", "token" => endpoint, "keys" => @keys})

      assert {:ok, registration} = Token.registration(web)
      stored = Token.stored(registration)
      assert Token.unstored("web_push", stored) == {endpoint, @keys}
      assert Token.unstored("fcm", "fcm:abc") == {"fcm:abc", nil}

      assert pointers(Token.registration(Map.delete(web, "keys"))) == [{"/keys", "required"}]

      assert pointers(Token.registration(Map.put(web, "token", "http://push.example.com/x"))) ==
               [{"/token", "invalid_format"}]

      assert pointers(Token.registration(body(%{"keys" => @keys}))) == [{"/keys", "not_allowed"}]
    end

    test "CH-72: a simulated provider token is accepted on every platform" do
      for platform <- ~w(apns fcm hms) do
        extra = if platform == "apns", do: %{"apns_environment" => "sandbox"}, else: %{}
        overrides = Map.merge(%{"platform" => platform, "token" => "sim:unregistered"}, extra)
        assert {:ok, %{token: "sim:unregistered"}} = Token.registration(body(overrides))
      end

      web = %{"platform" => "web_push", "token" => "sim:delivered", "keys" => @keys}
      assert {:ok, _registration} = Token.registration(body(web))
    end

    test "CH-31: a previous token is checked and normalised like the token" do
      assert {:ok, %{previous_token: "fcm:old"}} =
               Token.registration(body(%{"previous_token" => " fcm:old "}))

      assert pointers(Token.registration(body(%{"previous_token" => "has space"}))) ==
               [{"/previous_token", "invalid_format"}]
    end
  end
end
