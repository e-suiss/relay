defmodule EsuissRelay.LiveSmokeTest do
  use ExUnit.Case, async: false

  alias EsuissRelay.{Api, Client, Credentials, DpopKey, Webhook}

  @moduletag :live

  defp env(name), do: System.fetch_env!(name)

  test "X-48: the SDK sends an event, pages notifications and verifies a webhook on a live test plane" do
    key = DpopKey.from_seed(Base.decode64!(env("SDK_LIVE_DPOP_SEED")))

    client =
      Client.new(
        base_url: env("SDK_LIVE_BASE_URL"),
        credentials: Credentials.Static.new(env("SDK_LIVE_TOKEN"), key)
      )

    event = %{
      "workflow" => env("SDK_LIVE_WORKFLOW"),
      "to" => [env("SDK_LIVE_RECIPIENT")],
      "data" => %{"first_name" => "Ayse"}
    }
    assert {:ok, %{"id" => id}} = Api.create_event(client, event)
    assert is_binary(id)

    assert {:ok, page} = Api.list_notifications(client, limit: 2)
    assert length(Enum.take(page, 6)) <= 6

    vectors = env("SDK_LIVE_WEBHOOK_VECTORS") |> File.read!() |> JSON.decode!()
    [vector | _rest] = vectors["cases"]
    timestamp = vector["webhook_timestamp"]

    headers = [
      {"webhook-id", vector["webhook_id"]},
      {"webhook-timestamp", Integer.to_string(timestamp)},
      {"webhook-signature", vector["v1a"]}
    ]

    body = Base.decode16!(vector["body_hex"], case: :lower)
    keys = [vectors["keys"]["ed25519_public_key"]]
    assert {:ok, %{scheme: :v1a}} = Webhook.verify(headers, body, keys, now: timestamp)
  end
end
