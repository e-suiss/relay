defmodule Relay.Channels.Push.ContentTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Content

  defp kind(payload) do
    case Content.check(payload) do
      :ok -> :ok
      {:error, %{code: :push_content_forbidden, details: details}} -> details
    end
  end

  describe "INV-60 no code, secret or link in a push payload" do
    test "INV-60: one-time codes are refused in Turkish and English" do
      for text <- [
            "Doğrulama kodunuz: 482913",
            "Your verification code is 4821",
            "Giriş şifreniz 99812",
            "OTP 123456",
            "123456 is your login code",
            "Use code 7731 to sign in"
          ] do
        assert %{kind: :otp_code} = kind(%{"aps" => %{"alert" => %{"body" => text}}}), text
      end
    end

    test "INV-60: authentication links are refused" do
      for url <- [
            "https://app.example.com/login?token=abc",
            "https://app.example.com/x#access_token=abc",
            "https://app.example.com/magic-link/abc",
            "myapp://auth/callback?code=1",
            "https://app.example.com/reset-password/xyz"
          ] do
        assert %{kind: :auth_link} = kind(%{"data" => %{"url" => "Open " <> url}}), url
      end
    end

    test "INV-60: secrets and secret-typed values are refused" do
      jwt = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abc"
      assert %{kind: :secret, path: "data.0"} = kind(%{"data" => [jwt]})
      assert %{kind: :secret} = kind(%{"k" => "AKIAABCDEFGHIJKLMNOP"})
      assert %{kind: :secret, path: "x"} = kind(%{"x" => Relay.Redacted.wrap("hidden")})
      assert %{kind: :secret, path: "relay.password"} = kind(%{relay: %{password: "x"}})
    end

    test "INV-60: ordinary content passes and the error never carries the value" do
      for text <- [
            "Your order 123456 has shipped",
            "Flight TK1923 departs at 14:05",
            "https://shop.example.com/orders/42?utm_source=push",
            "Shopping list: 3 items",
            "Siparişiniz yola çıktı"
          ] do
        assert kind(%{"aps" => %{"alert" => %{"body" => text}}}) == :ok, text
      end

      {:error, error} = Content.check(%{"b" => "Kodunuz 123456"})
      refute inspect(error) =~ "123456"
    end
  end

  describe "CH-33 content-free mode" do
    test "CH-33: defaults follow region, policy and class; sensitive always" do
      assert Content.content_free?(%{region: "tr", message_class: :marketing})
      assert Content.content_free?(%{region: "eu", domestic_only: true})
      assert Content.content_free?(%{region: "us", message_class: :security})
      refute Content.content_free?(%{region: "eu", message_class: :transactional})
      assert Content.content_free?(%{region: "eu", choice: true})
      refute Content.content_free?(%{region: "tr", choice: false})
      assert Content.content_free?(%{region: "eu", sensitive: true, choice: false})
    end

    test "CH-67: the neutral lock screen text is the template's or a generic one" do
      assert Content.neutral("tr-TR") == %{
               "title" => "Yeni bildirim",
               "body" => "Yeni bir bildiriminiz var."
             }

      assert Content.neutral("de", nil)["body"] == "You have a new notification."
      assert Content.neutral(nil, "Hesabınızda bir hareket var")["body"] =~ "hareket"
    end
  end
end
