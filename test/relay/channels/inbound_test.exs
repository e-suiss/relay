defmodule Relay.Channels.InboundTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Inbound
  alias Relay.Redacted

  @now ~U[2026-11-05 12:00:00Z]
  @body ~s({"type":"delivered","id":"m1"})

  defp ts(offset_s \\ 0), do: Integer.to_string(DateTime.to_unix(@now) + offset_s)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp b64url(data), do: Base.url_encode64(data, padding: false)

  describe "T-40 TN-35 Standard Webhooks" do
    test "T-40, TN-35: a v1 signature over id, timestamp and the raw body verifies" do
      secret = :crypto.strong_rand_bytes(32)
      key = Redacted.wrap("whsec_" <> Base.encode64(secret))
      signature = Base.encode64(hmac(secret, "msg_1." <> ts() <> "." <> @body))

      headers = [
        {"webhook-id", "msg_1"},
        {"webhook-timestamp", ts()},
        {"webhook-signature", "v1,bm90IGl0 v1," <> signature}
      ]

      assert Inbound.standard_webhooks(key, @body, headers, @now) == :ok
      assert Relay.Channels.verify_standard_webhooks(key, @body, headers, @now) == :ok

      assert Inbound.standard_webhooks(key, @body <> " ", headers, @now) ==
               {:error, :bad_signature}

      stale = List.keyreplace(headers, "webhook-timestamp", 0, {"webhook-timestamp", ts(-301)})
      assert Inbound.standard_webhooks(key, @body, stale, @now) == {:error, :stale_timestamp}

      assert Inbound.standard_webhooks(key, @body, tl(headers), @now) ==
               {:error, :missing_header}
    end

    test "T-40: a v1a Ed25519 signature verifies with the public key" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      payload = "msg_2." <> ts() <> "." <> @body
      signature = :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      key = Redacted.wrap("whpk_" <> Base.encode64(public))

      headers = [
        {"webhook-id", "msg_2"},
        {"webhook-timestamp", ts()},
        {"webhook-signature", "v1a," <> Base.encode64(signature)}
      ]

      assert Inbound.standard_webhooks(key, @body, headers, @now) == :ok
      assert Inbound.standard_webhooks(key, "{}", headers, @now) == {:error, :bad_signature}
    end
  end

  describe "T-40 CH-60 CH-62 provider schemes" do
    test "CH-60, T-40: an HMAC of the raw body with a prefix, as X-Hub-Signature-256, verifies" do
      key = Redacted.wrap("app-secret")
      value = "sha256=" <> Base.encode16(hmac("app-secret", @body), case: :lower)
      headers = [{"x-hub-signature-256", value}]
      opts = [header: "x-hub-signature-256", prefix: "sha256="]

      assert Inbound.hmac(key, @body, headers, opts) == :ok
      assert Relay.Channels.verify_hmac(key, @body, headers, opts) == :ok
      assert Inbound.hmac(key, @body <> "x", headers, opts) == {:error, :bad_signature}

      assert Inbound.hmac(key, @body, [{"x-hub-signature-256", "md5=00"}], opts) ==
               {:error, :bad_signature}

      assert Inbound.hmac(key, @body, [], opts) == {:error, :missing_header}
    end

    test "CH-62, T-40: Slack's v0 signature is checked with its timestamp" do
      key = Redacted.wrap("slack-secret")
      signature = Base.encode16(hmac("slack-secret", "v0:" <> ts() <> ":" <> @body), case: :lower)

      headers = [
        {"x-slack-request-timestamp", ts()},
        {"x-slack-signature", "v0=" <> signature}
      ]

      assert Inbound.slack(key, @body, headers, @now) == :ok
      later = DateTime.add(@now, 600)
      assert Inbound.slack(key, @body, headers, later) == {:error, :stale_timestamp}
    end

    test "T-40: an Ed25519 signature over a timestamp and the body verifies" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      signature = :crypto.sign(:eddsa, :none, ts() <> @body, [private, :ed25519])
      encoded = Base.encode16(signature)
      headers = [{"x-signature-ed25519", encoded}, {"x-signature-timestamp", ts()}]

      opts = [header: "x-signature-ed25519", timestamp_header: "x-signature-timestamp", now: @now]

      assert Inbound.ed25519(Redacted.wrap(public), @body, headers, opts) == :ok

      assert Inbound.ed25519(Redacted.wrap(public), "{}", headers, opts) ==
               {:error, :bad_signature}
    end

    test "CH-62, T-40: a shared secret token is compared in constant time" do
      key = Redacted.wrap("token-1")
      name = "x-telegram-bot-api-secret-token"

      assert Inbound.secret_token(key, [{name, "token-1"}], name) == :ok
      assert Inbound.secret_token(key, [{name, "token-2"}], name) == {:error, :bad_signature}
      assert Inbound.secret_token(key, [], name) == {:error, :missing_header}
    end
  end

  describe "T-40 TN-35 JWT" do
    test "TN-35, T-40: an HS256 token verifies and returns its claims; none and expired tokens do not" do
      key = Redacted.wrap("jwt-secret")
      claims = %{"sub" => "provider", "exp" => DateTime.to_unix(@now) + 60}
      input = b64url(~s({"alg":"HS256","typ":"JWT"})) <> "." <> b64url(Jason.encode!(claims))
      token = input <> "." <> b64url(hmac("jwt-secret", input))

      assert Inbound.jwt(key, token, algs: ["HS256"], now: @now) == {:ok, claims}
      assert Relay.Channels.verify_jwt(key, token, algs: ["HS256"], now: @now) == {:ok, claims}
      assert Inbound.jwt(key, token, algs: ["RS256"], now: @now) == {:error, :bad_signature}

      assert Inbound.jwt(key, token, algs: ["HS256"], now: DateTime.add(@now, 3600)) ==
               {:error, :stale_timestamp}

      unsigned = b64url(~s({"alg":"none"})) <> "." <> b64url(Jason.encode!(claims)) <> "."
      algs = ["none", "HS256"]
      assert Inbound.jwt(key, unsigned, algs: algs, now: @now) == {:error, :bad_signature}
    end

    test "TN-35: an ES256 token with a raw R and S signature verifies with a PEM public key" do
      private = :public_key.generate_key({:namedCurve, :secp256r1})
      public = {{:ECPoint, elem(private, 4)}, elem(private, 3)}
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])

      input = b64url(~s({"alg":"ES256"})) <> "." <> b64url(~s({"sub":"p"}))
      der = :public_key.sign(input, :sha256, private)
      {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
      token = input <> "." <> b64url(<<r::unsigned-256, s::unsigned-256>>)

      assert Inbound.jwt(Redacted.wrap(pem), token, algs: ["ES256"], now: @now) ==
               {:ok, %{"sub" => "p"}}
    end
  end

  describe "CH-9 timeouts" do
    test "CH-9, WF-38: the channel time to live is expires_at minus now" do
      assert Relay.Channels.ttl_s(nil, @now) == nil
      assert Relay.Channels.ttl_s(DateTime.add(@now, 3600), @now) == 3600
      assert Relay.Channels.ttl_s(DateTime.add(@now, 1500, :millisecond), @now) == 1
      assert Relay.Channels.ttl_s(DateTime.add(@now, 999, :millisecond), @now) == :expired
    end

    test "CH-9, L-13: the call timeout is the shortest of the message, channel and provider layers" do
      soon = DateTime.add(@now, 2, :second)
      assert Relay.Channels.call_timeout_ms(nil, @now, nil, 10_000) == {:ok, 10_000}
      assert Relay.Channels.call_timeout_ms(nil, @now, 5_000, 10_000) == {:ok, 5_000}
      assert Relay.Channels.call_timeout_ms(soon, @now, 5_000, 10_000) == {:ok, 2_000}
      assert Relay.Channels.call_timeout_ms(@now, @now, nil, 10_000) == :expired
    end

    test "CH-9: Retry-After is read as delta seconds or an HTTP date" do
      assert Relay.Channels.retry_after_ms("30", @now) == 30_000
      assert Relay.Channels.retry_after_ms(" 0 ", @now) == 0
      assert Relay.Channels.retry_after_ms("Thu, 05 Nov 2026 12:01:00 GMT", @now) == 60_000
      assert Relay.Channels.retry_after_ms("Thu, 05 Nov 2026 11:00:00 GMT", @now) == 0
      assert Relay.Channels.retry_after_ms("soon", @now) == nil
      assert Relay.Channels.retry_after_ms(nil, @now) == nil
    end
  end

  describe "T-43 T-26 outbound requests" do
    test "T-43, T-26: certificate verification, retries and redirects cannot be turned on or off by options" do
      opts =
        Relay.Channels.http_options(
          url: "https://provider.example",
          retry: :transient,
          redirect: true,
          connect_options: [transport_opts: [verify: :verify_none, cacerts: []], timeout: 5_000]
        )

      assert opts[:retry] == false
      assert opts[:redirect] == false
      assert opts[:connect_options][:timeout] == 5_000
      refute Keyword.has_key?(opts[:connect_options][:transport_opts], :verify)
      assert Keyword.has_key?(opts[:connect_options][:transport_opts], :cacerts)
      plain = Relay.Channels.http_options(url: "https://p.example")
      refute Keyword.has_key?(plain, :connect_options)
    end
  end
end
