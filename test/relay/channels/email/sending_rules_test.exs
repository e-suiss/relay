defmodule Relay.Channels.Email.SendingRulesTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Headers
  alias Relay.Channels.Email.Smtputf8
  alias Relay.Channels.Email.Streams
  alias Relay.Channels.Email.Tracking
  alias Relay.Channels.Email.Verp

  @key :crypto.hash(:sha256, "verp-test-key")

  defp mac(message), do: {:ok, :crypto.mac(:hmac, :sha256, @key, message)}
  defp other_mac(message), do: {:ok, :crypto.mac(:hmac, :sha256, "another key", message)}

  defp feedback,
    do: %{campaign: "spring2026", category: "offers", tenant: "tenant1", sender: "offers"}

  defp unsubscribe,
    do: %{https: "https://relay.example/u/opaque", mailto: "mailto:u-opaque@sender.example"}

  defp config do
    %{
      "streams" => %{
        "transactional" => %{
          "from" => "no-reply@tx.sender.example",
          "domain" => "tx.sender.example",
          "selector" => "tx2026a",
          "return_path_domain" => "bounce.tx.sender.example",
          "ip_pool" => "pool-tx",
          "queue" => "email-tx"
        },
        "marketing" => %{
          "from" => "news@mkt.sender.example",
          "domain" => "mkt.sender.example",
          "selector" => "mkt2026a",
          "return_path_domain" => "bounce.mkt.sender.example",
          "ip_pool" => "pool-mkt",
          "queue" => "email-mkt"
        }
      },
      "categories" => %{
        "billing" => %{
          "class" => "transactional",
          "from" => "billing@tx.sender.example"
        }
      }
    }
  end

  describe "CH-38 VERP return path" do
    test "CH-38: a return path names its delivery and survives case folding" do
      id = Relay.Id.generate()
      assert {:ok, address} = Verp.encode(id, "Bounce.Sender.Example", &mac/1)

      assert [local, "bounce.sender.example"] = String.split(address, "@")
      assert "b-" <> _token = local
      assert byte_size(local) <= 64
      assert Verp.decode(address, &mac/1) == {:ok, id}
      assert Verp.decode(String.upcase(address), &mac/1) == {:ok, id}
      assert Verp.decode("<" <> address <> ">", &mac/1) == {:ok, id}
    end

    test "CH-39: a forged or foreign return path names no delivery" do
      {:ok, address} = Verp.encode(Relay.Id.generate(), "bounce.sender.example", &mac/1)
      [local, _domain] = String.split(address, "@")

      assert Verp.decode(address, &other_mac/1) == {:error, :forged}
      assert Verp.decode(local <> "@other.example", &mac/1) == {:error, :forged}
      assert Verp.decode("news@sender.example", &mac/1) == {:error, :not_verp}
      assert Verp.decode("b-notbase32!@sender.example", &mac/1) == {:error, :not_verp}
      assert Verp.decode("b-aaaa@sender.example", &mac/1) == {:error, :not_verp}
    end
  end

  describe "CH-38 mandatory headers" do
    test "CH-38: a bulk e-mail carries one-click unsubscribe and Feedback-ID, all signed" do
      assert {:ok, built} =
               Headers.build(%{
                 class: "marketing",
                 return_path: "b-x@bounce.sender.example",
                 feedback_id: feedback(),
                 unsubscribe: unsubscribe()
               })

      assert built.headers == [
               {"Feedback-ID", "spring2026:offers:tenant1:offers"},
               {"List-Unsubscribe",
                "<https://relay.example/u/opaque>, <mailto:u-opaque@sender.example>"},
               {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"}
             ]

      assert built.dkim_headers == ["feedback-id", "list-unsubscribe", "list-unsubscribe-post"]
      assert built.return_path == "b-x@bounce.sender.example"
    end

    test "CH-38: a transactional e-mail carries Feedback-ID and no List-Unsubscribe" do
      for class <- ["security", "transactional", "operational", "action_required"] do
        assert {:ok, %{headers: [{"Feedback-ID", _value}], dkim_headers: ["feedback-id"]}} =
                 Headers.build(%{
                   class: class,
                   return_path: "b-x@bounce.sender.example",
                   feedback_id: feedback()
                 })

        assert {:error, %Relay.Error{code: :invalid_email_headers}} =
                 Headers.build(%{
                   class: class,
                   return_path: "b-x@bounce.sender.example",
                   feedback_id: feedback(),
                   unsubscribe: unsubscribe()
                 })
      end
    end

    test "CH-38: a bulk e-mail without both unsubscribe URIs is refused" do
      plain = %{https: "http://plain.example/u", mailto: "mailto:u@x.example"}

      for unsubscribe <- [nil, plain] do
        assert {:error, %Relay.Error{code: :invalid_email_headers}} =
                 Headers.build(%{
                   class: "social",
                   return_path: "b-x@bounce.sender.example",
                   feedback_id: feedback(),
                   unsubscribe: unsubscribe
                 })
      end
    end

    test "CH-38: a Feedback-ID part with a colon or out of range is refused" do
      assert {:error, _error} = Headers.feedback_id(%{feedback() | campaign: "a:b"})
      assert {:error, _error} = Headers.feedback_id(%{feedback() | tenant: ""})
      parts = %{campaign: "c", category: "k", tenant: "t", sender: "s"}
      assert {:ok, "c:k:t:s"} = Headers.feedback_id(parts)
    end
  end

  describe "CH-43 tracking" do
    test "CH-43: tracking is off unless the tenant turns it on" do
      assert Tracking.plan(%{class: "marketing"}) == %{open_pixel: false, wrap_links: false}

      assert Tracking.plan(%{class: "marketing", open_pixel: true, wrap_links: true}) ==
               %{open_pixel: true, wrap_links: true}
    end

    test "CH-44: security and verification e-mails are never tracked, whatever the setting" do
      on = %{open_pixel: true, wrap_links: true}
      off = %{open_pixel: false, wrap_links: false}

      assert Tracking.plan(Map.put(on, :class, "security")) == off

      verification = %{class: "security", security_subtype: "email_verification"}
      assert Tracking.plan(Map.merge(on, verification)) == off

      otp = %{class: "transactional", security_subtype: "otp_oob"}
      assert Tracking.plan(Map.merge(on, otp)) == off
    end
  end

  describe "CH-35 streams" do
    test "CH-35: classes go out on their stream" do
      for class <- ["security", "transactional", "operational", "action_required"],
          do: assert(Streams.stream(class) == {:ok, "transactional"})

      assert Streams.stream("marketing") == {:ok, "marketing"}
      assert Streams.stream("social") == {:ok, "marketing"}
      assert {:error, %Relay.Error{code: :no_email_stream}} = Streams.stream("system")
    end

    test "CH-35: a valid configuration separates the streams" do
      assert Streams.validate(config()) == :ok
    end

    test "CH-35: streams that share a pool, queue, domain or selector are refused" do
      for key <- ["ip_pool", "queue", "domain", "selector"] do
        shared = get_in(config(), ["streams", "transactional", key])
        broken = put_in(config(), ["streams", "marketing", key], shared)
        assert {:error, %Relay.Error{code: :invalid_email_streams}} = Streams.validate(broken)
      end
    end

    test "CH-35: a category may not send from the other stream's domain" do
      broken = put_in(config(), ["categories", "billing", "domain"], "mkt.sender.example")

      assert {:error, %Relay.Error{code: :invalid_email_streams}} = Streams.validate(broken)
    end

    test "CH-35: the sender identity is the stream's, with the category's from address" do
      assert {:ok, sender} = Streams.sender(config(), "transactional", "billing")
      assert sender.from == "billing@tx.sender.example"
      assert sender.domain == "tx.sender.example"
      assert sender.ip_pool == "pool-tx"

      assert {:ok, %{from: "news@mkt.sender.example", queue: "email-mkt"}} =
               Streams.sender(config(), "marketing", nil)
    end
  end

  describe "CH-45 SMTPUTF8" do
    test "CH-45: an internationalized address is never refused when the provider supports it" do
      assert Smtputf8.check(["reader@example.com"], false) == {:ok, false}
      assert Smtputf8.check(["yönetici@örnek.example"], true) == {:ok, true}
    end

    test "CH-45: an unsupported provider fails the delivery as permanent_content" do
      assert {:error, %Relay.Error{code: :smtputf8_unsupported, details: details}} =
               Smtputf8.check(["reader@example.com", "çağrı@example.com"], false)

      assert details.failure_class == "permanent_content"
    end
  end
end
