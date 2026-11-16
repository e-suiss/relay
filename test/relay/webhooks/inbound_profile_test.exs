defmodule Relay.Webhooks.InboundProfileTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Profile

  @vectors "conformance/webhooks/vectors/1/signature.json" |> File.read!() |> Jason.decode!()
  @public @vectors["keys"]["ed25519_public_key"]
  @secret @vectors["keys"]["hmac_secret"]
  @tolerance Relay.Limits.seconds!(["webhook", "signature_tolerance"])

  defp at(unix), do: DateTime.from_unix!(unix)

  defp body(vector), do: Base.decode16!(vector["body_hex"], case: :lower)

  defp vector(name), do: Enum.find(@vectors["cases"], &(&1["name"] == name))

  defp headers(id, timestamp, signature) do
    [
      {"webhook-id", id},
      {"webhook-timestamp", Integer.to_string(timestamp)},
      {"webhook-signature", signature}
    ]
  end

  defp keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {Profile.public_key_text(public), private}
  end

  defp token(private, id, timestamp, body) do
    content = Profile.signed_content(id, timestamp, body)
    Profile.token(:v1a, :crypto.sign(:eddsa, :none, content, [private, :ed25519]))
  end

  defp provider(key, body, headers, now),
    do: Relay.Channels.verify_standard_webhooks(Redacted.wrap(key), body, headers, now)

  describe "WH-49 WH-50 WH-51 one verifier" do
    test "WH-4, WH-49, WH-50, E-48, E-36: every shared vector verifies through the inbound paths" do
      assert @tolerance == @vectors["tolerance_s"]
      assert length(@vectors["cases"]) >= 3

      for %{"webhook_id" => id, "webhook_timestamp" => timestamp} = vector <- @vectors["cases"],
          {scheme, tag, key} <- [{:v1a, "v1a", @public}, {:v1, "v1", @secret}] do
        headers = headers(id, timestamp, vector[tag])
        now = at(timestamp)

        assert Relay.Webhooks.verify_message(headers, body(vector), [key], now) ==
                 {:ok, %{id: id, timestamp: timestamp, scheme: scheme}}

        assert Relay.Webhooks.verify_message(headers, body(vector), [Redacted.wrap(key)], now) ==
                 {:ok, %{id: id, timestamp: timestamp, scheme: scheme}}

        assert provider(key, body(vector), headers, now) == :ok
      end
    end

    test "WH-4, WH-49: the shared rejections are refused on the inbound paths" do
      for rejection <- @vectors["rejections"], base = vector(rejection["case"]) do
        id = Map.get(rejection, "webhook_id", base["webhook_id"])
        raw = body(Map.merge(base, Map.take(rejection, ["body_hex"])))
        now = at(Map.get(rejection, "now", base["webhook_timestamp"]))

        signature =
          if rejection["swap_versions"] do
            "v1a," <> ed25519 = base["v1a"]
            "v1," <> hmac = base["v1"]
            "v1," <> ed25519 <> " v1a," <> hmac
          else
            base["v1a"] <> " " <> base["v1"]
          end

        headers = headers(id, base["webhook_timestamp"], signature)

        assert {:error, reason} =
                 Relay.Webhooks.verify_message(headers, raw, [@public, @secret], now)

        assert reason in [:no_matching_signature, :timestamp_out_of_tolerance], rejection["name"]
        assert {:error, refused} = provider(@public, raw, headers, now)
        assert refused in [:bad_signature, :stale_timestamp], rejection["name"]
      end
    end

    test "WH-6, WH-51, WH-49: a message signed by both keys of a rotation overlap is accepted under either" do
      {old_public, old_private} = keypair()
      {new_public, new_private} = keypair()
      {other_public, _other_private} = keypair()
      raw = ~s({"type":"consent.updated","id":"evt_1"})
      now = ~U[2026-11-16 09:00:00Z]
      timestamp = DateTime.to_unix(now)

      tokens = [
        token(new_private, "evt_1", timestamp, raw),
        token(old_private, "evt_1", timestamp, raw)
      ]

      both = Profile.headers("evt_1", timestamp, tokens)
      verified = {:ok, %{id: "evt_1", timestamp: timestamp, scheme: :v1a}}

      assert Relay.Webhooks.verify_message(both, raw, [old_public], now) == verified
      assert Relay.Webhooks.verify_message(both, raw, [new_public], now) == verified
      assert provider(old_public, raw, both, now) == :ok
      assert provider(new_public, raw, both, now) == :ok

      old_only = Profile.headers("evt_1", timestamp, [hd(tl(tokens))])
      keys = [new_public, old_public]
      assert Relay.Webhooks.verify_message(old_only, raw, keys, now) == verified

      assert Relay.Webhooks.verify_message(both, raw, [other_public], now) ==
               {:error, :no_matching_signature}

      assert Relay.Webhooks.verify_message(both, raw, ["not a key"], now) ==
               {:error, :no_matching_signature}
    end

    test "WH-7, WH-49: the raw body is verified as it arrived; a body serialised again is refused" do
      base = vector("standard-webhooks-reference-body")
      headers = headers(base["webhook_id"], base["webhook_timestamp"], base["v1a"])
      now = at(base["webhook_timestamp"])
      again = base |> body() |> Jason.decode!() |> Jason.encode!()

      assert again != body(base)

      assert Relay.Webhooks.verify_message(headers, again, [@public], now) ==
               {:error, :no_matching_signature}

      assert provider(@public, again, headers, now) == {:error, :bad_signature}
    end

    test "WH-7: a timestamp further than the signature tolerance limit is refused in both directions" do
      base = vector("standard-webhooks-reference-body")
      timestamp = base["webhook_timestamp"]
      headers = headers(base["webhook_id"], timestamp, base["v1a"])
      raw = body(base)

      for offset <- [-@tolerance, 0, @tolerance] do
        assert {:ok, _verified} =
                 Relay.Webhooks.verify_message(headers, raw, [@public], at(timestamp + offset))
      end

      for offset <- [-@tolerance - 1, @tolerance + 1] do
        now = at(timestamp + offset)

        assert Relay.Webhooks.verify_message(headers, raw, [@public], now) ==
                 {:error, :timestamp_out_of_tolerance}

        assert provider(@public, raw, headers, now) == {:error, :stale_timestamp}
      end
    end

    test "WH-4, WH-49: a missing or repeated profile header is refused" do
      base = vector("standard-webhooks-reference-body")
      headers = headers(base["webhook_id"], base["webhook_timestamp"], base["v1a"])
      now = at(base["webhook_timestamp"])
      raw = body(base)

      for name <- Profile.header_names() do
        missing = List.keydelete(headers, name, 0)

        assert Relay.Webhooks.verify_message(missing, raw, [@public], now) ==
                 {:error, :missing_header}

        assert provider(@public, raw, missing, now) == {:error, :missing_header}

        repeated = headers ++ [List.keyfind(headers, name, 0)]

        assert Relay.Webhooks.verify_message(repeated, raw, [@public], now) ==
                 {:error, :duplicate_header}

        assert provider(@public, raw, repeated, now) == {:error, :bad_signature}
      end
    end

    test "WH-9: the unsigned headers carry no security meaning" do
      base = vector("standard-webhooks-reference-body")
      headers = headers(base["webhook_id"], base["webhook_timestamp"], base["v1a"])
      now = at(base["webhook_timestamp"])
      unsigned = [{"webhook-event-type", "anything.else"}, {"webhook-attempt", "999"}]

      assert Relay.Webhooks.verify_message(headers ++ unsigned, body(base), [@public], now) ==
               Relay.Webhooks.verify_message(headers, body(base), [@public], now)

      assert {:ok, _verified} =
               Relay.Webhooks.verify_message(headers ++ unsigned, body(base), [@public], now)
    end

    test "WH-49: a provider with a signature scheme of its own is unaffected by the profile" do
      key = Redacted.wrap("app-secret")
      raw = ~s({"type":"delivered","id":"m1"})
      mac = Base.encode16(:crypto.mac(:hmac, :sha256, "app-secret", raw), case: :lower)
      own = [{"x-hub-signature-256", "sha256=" <> mac}]
      opts = [header: "x-hub-signature-256", prefix: "sha256="]

      profile = [
        {"webhook-id", "msg_1"},
        {"webhook-timestamp", "1"},
        {"webhook-signature", "v1a,bm90IGl0"}
      ]

      assert Relay.Channels.verify_hmac(key, raw, own, opts) == :ok
      assert Relay.Channels.verify_hmac(key, raw, own ++ profile, opts) == :ok
      assert Relay.Channels.verify_hmac(key, raw, profile, opts) == {:error, :missing_header}

      assert Relay.Channels.verify_standard_webhooks(key, raw, own, ~U[2026-11-16 09:00:00Z]) ==
               {:error, :missing_header}
    end
  end
end
