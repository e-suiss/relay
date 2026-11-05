defmodule Relay.Channels.Push.WebPushTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.WebPush
  alias Relay.Channels.Push.WebPush.Encryption

  setup do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    auth = :crypto.strong_rand_bytes(16)

    push = %{
      endpoint: "https://push.example/send/abc",
      p256dh: public,
      auth: auth,
      payload: ~s({"hello":"world"}),
      ttl: 600,
      urgency: :high,
      authorization: "vapid t=a.b.c, k=key",
      topic: "subjectKey_32_characters_long_xx"
    }

    %{push: push, private: private, auth: auth}
  end

  describe "CH-26 requests" do
    test "CH-26: the request carries the encrypted body and the headers", ctx do
      assert {:ok, request} = WebPush.request(ctx.push)
      headers = Map.new(request.headers)

      assert request.url == "https://push.example/send/abc"
      assert headers["content-encoding"] == "aes128gcm"
      assert headers["ttl"] == "600"
      assert headers["urgency"] == "high"
      assert headers["topic"] == "subjectKey_32_characters_long_xx"
      assert headers["authorization"] == "vapid t=a.b.c, k=key"

      assert Encryption.decrypt(request.body, ctx.private, ctx.auth) ==
               {:ok, ~s({"hello":"world"})}
    end

    test "CH-26: there is no silent Web Push" do
      assert {:error, %{code: :web_push_silent}} = WebPush.request(%{ctx_push() | urgency: nil})
    end

    test "CH-23: Topic is at most 32 base64url characters", ctx do
      long = %{ctx.push | topic: String.duplicate("a", 33)}
      assert {:error, %{code: :web_push_topic_invalid}} = WebPush.request(long)
      plus = %{ctx.push | topic: "a+b"}
      assert {:error, %{code: :web_push_topic_invalid}} = WebPush.request(plus)
      assert {:ok, request} = WebPush.request(%{ctx.push | topic: nil})
      refute List.keymember?(request.headers, "topic", 0)
    end
  end

  describe "T-38 payloads" do
    test "T-38: the declarative payload has the magic member, title and navigate" do
      notification = %{
        title: "Order shipped",
        navigate: "https://shop.example/orders/42",
        body: "On its way",
        lang: "en",
        dir: "ltr",
        app_badge: 3,
        actions: [%{title: "Track", action: "track", navigate: "https://shop.example/t/42"}]
      }

      assert {:ok, json} = WebPush.declarative(notification, mutable: true)

      assert Jason.decode!(json) == %{
               "web_push" => 8030,
               "notification" => %{
                 "title" => "Order shipped",
                 "navigate" => "https://shop.example/orders/42",
                 "body" => "On its way",
                 "lang" => "en",
                 "dir" => "ltr",
                 "app_badge" => "3",
                 "actions" => [
                   %{
                     "action" => "track",
                     "title" => "Track",
                     "navigate" => "https://shop.example/t/42"
                   }
                 ]
               },
               "mutable" => true
             }

      assert String.starts_with?(json, ~s({"web_push":8030,"notification":{"title"))
    end

    test "T-38: a declarative payload without title or an HTTPS navigate is refused" do
      assert {:error, %{code: :push_payload_invalid}} = WebPush.declarative(%{title: "x"})

      assert {:error, %{code: :push_payload_invalid}} =
               WebPush.declarative(%{title: "x", navigate: "http://insecure.example"})

      bad_action = %{title: "x", navigate: "https://a.example", actions: [%{title: "t"}]}
      assert {:error, %{code: :push_payload_invalid}} = WebPush.declarative(bad_action)
    end

    test "CH-26: payloads over the plaintext limit are refused" do
      assert {:ok, _json} = WebPush.classic(%{"a" => "b"})

      assert {:error, %{code: :push_payload_too_large}} =
               WebPush.classic(%{"a" => String.duplicate("b", Encryption.max_plaintext())})
    end
  end

  defp ctx_push do
    %{
      endpoint: "https://push.example/x",
      p256dh: <<4, 0::512>>,
      auth: <<0::128>>,
      payload: "",
      ttl: 0,
      urgency: :low,
      authorization: "vapid t=x, k=y"
    }
  end
end
