defmodule EsuissRelay.WebhookTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Webhook

  @vectors "../../conformance/webhooks/vectors/1/signature.json"
           |> File.read!()
           |> JSON.decode!()
  @tolerance @vectors["tolerance_s"]
  @public @vectors["keys"]["ed25519_public_key"]
  @hmac @vectors["keys"]["hmac_secret"]

  defp body(vector), do: Base.decode16!(vector["body_hex"], case: :lower)

  defp vector(name), do: Enum.find(@vectors["cases"], &(&1["name"] == name))

  defp headers(id, timestamp, signature) do
    [
      {"Webhook-Id", id},
      {"webhook-timestamp", Integer.to_string(timestamp)},
      {"webhook-signature", signature}
    ]
  end

  defp signature(%{"swap_versions" => true}, base) do
    "v1a," <> ed25519 = base["v1a"]
    "v1," <> hmac = base["v1"]
    "v1," <> ed25519 <> " v1a," <> hmac
  end

  defp signature(_rejection, base), do: base["v1a"] <> " " <> base["v1"]

  test "WH-4: every shared vector verifies with its Ed25519 key, its HMAC secret or both" do
    for vector <- @vectors["cases"] do
      %{"webhook_id" => id, "webhook_timestamp" => timestamp} = vector
      opts = [now: timestamp, tolerance: @tolerance]

      assert Webhook.signed_content(id, timestamp, body(vector)) ==
               Base.decode16!(vector["signed_content_hex"], case: :lower)

      assert {:ok, %{id: ^id, timestamp: ^timestamp, scheme: :v1a}} =
               Webhook.verify(
                 headers(id, timestamp, vector["v1a"]),
                 body(vector),
                 [@public],
                 opts
               )

      assert {:ok, %{scheme: :v1}} =
               Webhook.verify(headers(id, timestamp, vector["v1"]), body(vector), [@hmac], opts)

      both = headers(id, timestamp, vector["v1"] <> " " <> vector["v1a"])

      for keys <- [[@public], [@hmac], [@hmac, @public]] do
        assert {:ok, _verified} = Webhook.verify(both, body(vector), keys, opts)
      end
    end
  end

  test "WH-4: every shared rejection is refused with either key" do
    for rejection <- @vectors["rejections"], keys <- [[@public], [@hmac]] do
      base = vector(rejection["case"])
      id = Map.get(rejection, "webhook_id", base["webhook_id"])
      timestamp = base["webhook_timestamp"]
      now = Map.get(rejection, "now", timestamp)
      body = Base.decode16!(Map.get(rejection, "body_hex", base["body_hex"]), case: :lower)

      assert {:error, _reason} =
               Webhook.verify(
                 headers(id, timestamp, signature(rejection, base)),
                 body,
                 keys,
                 now: now,
                 tolerance: @tolerance
               )
    end
  end

  test "WH-7: a timestamp outside the tolerance is refused in both directions" do
    vector = vector("standard-webhooks-reference-body")
    timestamp = vector["webhook_timestamp"]
    signed = headers(vector["webhook_id"], timestamp, vector["v1a"])

    for now <- [timestamp - 301, timestamp + 301] do
      assert {:error, :timestamp_out_of_tolerance} =
               Webhook.verify(signed, body(vector), [@public], now: now)
    end

    assert {:ok, _verified} =
             Webhook.verify(signed, body(vector), [@public], now: timestamp + 300)
  end

  test "WH-7: missing, duplicate and malformed headers and unknown keys are refused" do
    vector = vector("empty-body")
    timestamp = vector["webhook_timestamp"]
    signed = headers(vector["webhook_id"], timestamp, vector["v1a"])
    opts = [now: timestamp]

    assert {:error, :missing_header} = Webhook.verify(tl(signed), "", [@public], opts)

    assert {:error, :duplicate_header} =
             Webhook.verify([{"webhook-id", "x"} | signed], "", [@public], opts)

    assert {:error, :malformed_header} =
             Webhook.verify(
               headers(vector["webhook_id"], timestamp, "v1a,???"),
               "",
               [@public],
               opts
             )

    assert {:error, :invalid_key} = Webhook.verify(signed, "", ["whpk_short"], opts)
    assert {:ok, _verified} = Webhook.verify(Map.new(signed), "", [@public], opts)
  end

  test "WH-4: a signature of a scheme the profile does not know is skipped" do
    vector = vector("empty-body")
    timestamp = vector["webhook_timestamp"]
    signed = headers(vector["webhook_id"], timestamp, "v2,AAAA " <> vector["v1a"])

    assert {:ok, %{scheme: :v1a}} = Webhook.verify(signed, "", [@public], now: timestamp)
  end
end
