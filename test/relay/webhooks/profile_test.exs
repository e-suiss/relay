defmodule Relay.Webhooks.ProfileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.Profile

  @vectors "conformance/webhooks/vectors/1/signature.json" |> File.read!() |> Jason.decode!()
  @tolerance @vectors["tolerance_s"]

  defp public_key do
    {:ok, key} = Profile.parse_key(@vectors["keys"]["ed25519_public_key"])
    key
  end

  defp hmac_key do
    {:ok, key} = Profile.parse_key(@vectors["keys"]["hmac_secret"])
    key
  end

  defp seed do
    "whsk_" <> encoded = @vectors["keys"]["ed25519_signing_key"]
    Base.decode64!(encoded)
  end

  defp ed25519_token(seed, id, timestamp, body) do
    content = Profile.signed_content(id, timestamp, body)
    Profile.token(:v1a, :crypto.sign(:eddsa, :none, content, [seed, :ed25519]))
  end

  defp sign(private, id, timestamp, body),
    do: Profile.headers(id, timestamp, [ed25519_token(private, id, timestamp, body)])

  defp message,
    do: tuple({binary(), binary(min_length: 1, max_length: 4), integer(0..4_000_000_000)})

  defp swapped(%{"swap_versions" => true}, base) do
    "v1a," <> ed25519 = base["v1a"]
    "v1," <> hmac = base["v1"]
    "v1," <> ed25519 <> " v1a," <> hmac
  end

  defp swapped(_rejection, base), do: base["v1a"] <> " " <> base["v1"]

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
    {{:ed25519, public}, private}
  end

  describe "WH-4 shared vectors" do
    test "WH-4: every shared vector gives the published signed content and both signatures" do
      assert length(@vectors["cases"]) >= 3

      for vector <- @vectors["cases"] do
        %{"webhook_id" => id, "webhook_timestamp" => timestamp} = vector
        body = body(vector)

        assert Profile.signed_content(id, timestamp, body) ==
                 Base.decode16!(vector["signed_content_hex"], case: :lower)

        {:hmac, secret} = hmac_key()
        v1 = Profile.hmac_token(secret, id, timestamp, body)
        v1a = ed25519_token(seed(), id, timestamp, body)

        assert Profile.signature_header([v1]) == vector["v1"]
        assert Profile.signature_header([v1a]) == vector["v1a"]
        assert Profile.signature_header([v1a, v1]) == vector["v1a"] <> " " <> vector["v1"]

        assert Profile.headers(id, timestamp, [v1a]) == headers(id, timestamp, vector["v1a"])
      end
    end

    test "WH-4: every shared vector verifies with the key of its scheme, alone or together" do
      for vector <- @vectors["cases"] do
        %{"webhook_id" => id, "webhook_timestamp" => timestamp} = vector
        body = body(vector)
        both = vector["v1"] <> " " <> vector["v1a"]

        ed25519 = headers(id, timestamp, vector["v1a"])
        hmac = headers(id, timestamp, vector["v1"])
        signed = headers(id, timestamp, both)
        now = at(timestamp)

        assert {:ok, %{id: ^id, timestamp: ^timestamp, scheme: :v1a}} =
                 Profile.verify(ed25519, body, [public_key()], now, @tolerance)

        assert {:ok, %{scheme: :v1}} = Profile.verify(hmac, body, [hmac_key()], now, @tolerance)

        for keys <- [[public_key()], [hmac_key()], [hmac_key(), public_key()]] do
          assert {:ok, _verified} = Profile.verify(signed, body, keys, now, @tolerance)
        end
      end
    end

    test "WH-4: the HMAC example published by Standard Webhooks verifies" do
      vector = vector("standard-webhooks-reference-body")
      assert vector["webhook_id"] == "msg_p5jXN8AQM9LWM0D4loKWxJek"
      assert vector["webhook_timestamp"] == 1_614_265_330
      assert body(vector) == ~s({"test": 2432232314})

      signed = headers(vector["webhook_id"], vector["webhook_timestamp"], vector["v1"])
      now = at(vector["webhook_timestamp"])

      assert {:ok, %{scheme: :v1}} =
               Profile.verify(signed, body(vector), [hmac_key()], now, @tolerance)
    end

    test "WH-4: the shared rejections are refused with either key" do
      assert length(@vectors["rejections"]) >= 4

      for rejection <- @vectors["rejections"], keys <- [[public_key()], [hmac_key()]] do
        base = vector(rejection["case"])
        id = Map.get(rejection, "webhook_id", base["webhook_id"])
        timestamp = base["webhook_timestamp"]
        now = Map.get(rejection, "now", timestamp)
        body = Base.decode16!(Map.get(rejection, "body_hex", base["body_hex"]), case: :lower)

        signed = headers(id, timestamp, swapped(rejection, base))

        assert {:error, _rejection} = Profile.verify(signed, body, keys, at(now), @tolerance)
      end
    end
  end

  describe "WH-7 TN-32 TN-35 verification rules" do
    property "TN-32: any raw bytes verify exactly as they were signed and fail after any change" do
      {key, private} = keypair()

      check all {body, suffix, timestamp} <- message() do
        id = "evt_" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
        signed = sign(private, id, timestamp, body)

        assert {:ok, %{id: ^id}} = Profile.verify(signed, body, [key], at(timestamp), @tolerance)

        assert {:error, :no_matching_signature} =
                 Profile.verify(signed, body <> suffix, [key], at(timestamp), @tolerance)
      end
    end

    test "TN-32: a body that was parsed and serialised again does not verify" do
      {key, private} = keypair()
      body = ~s({"b": 1,  "a": 2})
      signed = sign(private, "evt_1", 1_800_000_000, body)
      again = body |> Jason.decode!() |> Jason.encode!()

      assert {:ok, _verified} = Profile.verify(signed, body, [key], at(1_800_000_000), @tolerance)

      assert {:error, :no_matching_signature} =
               Profile.verify(signed, again, [key], at(1_800_000_000), @tolerance)
    end

    test "WH-7: the timestamp tolerance is five minutes in both directions" do
      {key, private} = keypair()
      timestamp = 1_800_000_000
      signed = sign(private, "evt_1", timestamp, "{}")

      for offset <- [-300, -1, 0, 1, 300] do
        assert {:ok, _verified} = Profile.verify(signed, "{}", [key], at(timestamp + offset), 300)
      end

      for offset <- [-301, 301, 86_400] do
        assert {:error, :timestamp_out_of_tolerance} =
                 Profile.verify(signed, "{}", [key], at(timestamp + offset), 300)
      end
    end

    test "WH-7: the timestamp is signed, so a renewed timestamp needs a new signature" do
      {key, private} = keypair()
      token = ed25519_token(private, "evt_1", 1_800_000_000, "{}")
      moved = Profile.headers("evt_1", 1_800_000_060, [token])

      assert {:error, :no_matching_signature} =
               Profile.verify(moved, "{}", [key], at(1_800_000_060), 300)
    end

    test "TN-35: an HMAC signature is accepted only for the secret that made it" do
      secret = :crypto.hash(:sha256, "first")
      other = :crypto.hash(:sha256, "second")
      token = Profile.hmac_token(secret, "evt_1", 1_800_000_000, "{}")
      signed = Profile.headers("evt_1", 1_800_000_000, [token])
      now = at(1_800_000_000)

      assert {:ok, %{scheme: :v1}} = Profile.verify(signed, "{}", [{:hmac, secret}], now, 300)

      assert {:ok, %{scheme: :v1}} =
               Profile.verify(signed, "{}", [{:hmac, Relay.Redacted.wrap(secret)}], now, 300)

      assert {:error, :no_matching_signature} =
               Profile.verify(signed, "{}", [{:hmac, other}], now, 300)

      assert {:error, :no_matching_signature} = Profile.verify(signed, "{}", [], now, 300)
    end
  end

  describe "WH-6 rotation overlap" do
    test "WH-6: a message signed with the new and the old key verifies against either of them" do
      {new_key, new_private} = keypair()
      {old_key, old_private} = keypair()
      {stranger, _private} = keypair()
      timestamp = 1_800_000_000

      tokens = [
        ed25519_token(new_private, "evt_1", timestamp, "{}"),
        ed25519_token(old_private, "evt_1", timestamp, "{}")
      ]

      signed = Profile.headers("evt_1", timestamp, tokens)
      [{_name, signature}] = Enum.filter(signed, &(elem(&1, 0) == "webhook-signature"))
      assert [<<"v1a,", _new::binary>>, <<"v1a,", _old::binary>>] = String.split(signature, " ")

      for keys <- [[new_key], [old_key], [stranger, old_key], [new_key, old_key]] do
        assert {:ok, %{scheme: :v1a}} = Profile.verify(signed, "{}", keys, at(timestamp), 300)
      end

      assert {:error, :no_matching_signature} =
               Profile.verify(signed, "{}", [stranger], at(timestamp), 300)
    end

    test "WH-6: a signature of a scheme the profile does not know is skipped, a broken one refuses the header" do
      {key, private} = keypair()
      timestamp = 1_800_000_000
      good = Profile.signature_header([ed25519_token(private, "evt_1", timestamp, "{}")])
      verify = &Profile.verify(headers("evt_1", timestamp, &1), "{}", [key], at(timestamp), 300)

      assert {:ok, _verified} = verify.("v2,AAAA " <> good)
      assert {:error, :no_matching_signature} = verify.("v2,AAAA")
      assert {:error, :malformed_header} = verify.("")
      assert {:error, :malformed_header} = verify.("v1a,not-base64 " <> good)
      assert {:error, :malformed_header} = verify.("v1a,AAAA " <> good)
      assert {:error, :malformed_header} = verify.("garbage " <> good)
    end
  end

  describe "WH-49 WH-50 WH-51 one verifier for inbound webhooks" do
    setup do
      {key, private} = keypair()
      timestamp = 1_800_000_000
      token = ed25519_token(private, "evt_1", timestamp, "{}")
      %{key: key, now: at(timestamp), signed: Profile.headers("evt_1", timestamp, [token])}
    end

    test "WH-49: request headers are read as a list or a map, in any letter case", ctx do
      [{_id, id}, {_timestamp, timestamp}, {_signature, signature}] = ctx.signed

      list = [
        {"content-type", "application/json"},
        {"Webhook-Id", id},
        {"WEBHOOK-TIMESTAMP", timestamp},
        {"webhook-signature", signature}
      ]

      map = %{
        "webhook-id" => [id],
        "webhook-timestamp" => timestamp,
        "Webhook-Signature" => signature
      }

      assert {:ok, %{id: "evt_1"}} = Profile.verify(list, "{}", [ctx.key], ctx.now, 300)
      assert {:ok, %{id: "evt_1"}} = Profile.verify(map, "{}", [ctx.key], ctx.now, 300)
    end

    test "WH-49: a missing, repeated or malformed profile header is refused", ctx do
      verify = &Profile.verify(&1, "{}", [ctx.key], ctx.now, 300)

      for name <- Profile.header_names() do
        without = Enum.reject(ctx.signed, &(elem(&1, 0) == name))
        assert {:error, :missing_header} = verify.(without)

        twice = ctx.signed ++ Enum.filter(ctx.signed, &(elem(&1, 0) == name))
        assert {:error, :duplicate_header} = verify.(twice)
      end

      replace = fn name, value -> List.keyreplace(ctx.signed, name, 0, {name, value}) end

      timestamps = ["", "abc", "1.5", "-1", "01800000000", " 1800000000", "1800000000000000"]

      for timestamp <- timestamps do
        assert {:error, :malformed_header} = verify.(replace.("webhook-timestamp", timestamp))
      end

      for id <- ["", "evt 1", "evt\n1", String.duplicate("a", 257)] do
        assert {:error, :malformed_header} = verify.(replace.("webhook-id", id))
      end

      assert {:error, :malformed_header} = verify.(replace.("webhook-signature", 1))
    end

    test "WH-50, WH-51: the verifier needs only the headers, the raw body and the keys", ctx do
      assert {:ok, %{id: "evt_1", timestamp: 1_800_000_000, scheme: :v1a}} =
               Profile.verify(ctx.signed, "{}", [ctx.key], ctx.now, 300)
    end
  end

  describe "WH-9 unsigned convenience headers" do
    test "WH-9: the event type and the attempt number are not signed and change nothing" do
      {key, private} = keypair()
      timestamp = 1_800_000_000
      signed = sign(private, "evt_1", timestamp, "{}")

      unsigned = [{"webhook-event-type", "order.shipped"}, {"webhook-attempt", "3"}]
      assert Profile.unsigned_headers("order.shipped", 3) == unsigned

      assert Profile.unsigned_header_names() -- Profile.header_names() ==
               Profile.unsigned_header_names()

      for unsigned <- [Profile.unsigned_headers("a.b", 3), [{"webhook-attempt", "9"}]] do
        with_unsigned = signed ++ unsigned
        assert {:ok, _verified} = Profile.verify(with_unsigned, "{}", [key], at(timestamp), 300)
      end
    end
  end

  describe "WH-4 keys" do
    test "WH-4: keys are read from their text forms and a public key is written back" do
      text = @vectors["keys"]["ed25519_public_key"]
      assert {:ok, {:ed25519, public}} = Profile.parse_key(text)
      assert Profile.public_key_text(public) == text

      assert {:ok, {:hmac, %Relay.Redacted{} = secret}} =
               Profile.parse_key(@vectors["keys"]["hmac_secret"])

      assert byte_size(Relay.Redacted.expose(secret)) == 24
      refute inspect(secret) =~ Base.encode64(Relay.Redacted.expose(secret))

      for text <- ["whpk_AAAA", "whsec_AAAA", "whpk_not base64", "plain", nil] do
        assert Profile.parse_key(text) == :error
      end
    end
  end
end
