defmodule Relay.Templates.Channel.InboxWebhookTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Channel.Inbox
  alias Relay.Templates.Channel.Webhook

  describe "TP-9 TP-29 inbox" do
    test "structured fields carry locale and dir" do
      fields = %{
        "title" => "Fatura",
        "body" => "Faturanız hazır",
        "actions" => [%{"label" => "Görüntüle", "url" => "https://example.com/i/1"}],
        "avatar" => "https://cdn.example.com/a.png"
      }

      assert {:ok, %{output: output, changes: []}} = Inbox.render(fields, locale: "ar-EG")

      assert output == %{
               title: "Fatura",
               body: "Faturanız hazır",
               actions: [%{label: "Görüntüle", url: "https://example.com/i/1"}],
               avatar: "https://cdn.example.com/a.png",
               locale: "ar-EG",
               dir: "rtl"
             }
    end

    test "the body is required and a dangerous action URL is refused" do
      fields = %{
        "actions" => [
          %{"label" => "Aç", "url" => " JavaScript:alert(1)"},
          %{"label" => " ", "url" => "/inbox"},
          "not an action"
        ],
        "avatar" => "http://example.com/a.png"
      }

      assert {:error, findings} = Inbox.render(fields, locale: "tr")

      assert Enum.map(findings, &{&1.check, &1.pointer}) == [
               {:inbox_body_missing, "/body"},
               {:inbox_avatar_url, "/avatar"},
               {:inbox_action_url, "/actions/0/url"},
               {:inbox_action_label, "/actions/1/label"},
               {:inbox_action, "/actions/2"}
             ]

      assert Enum.all?(findings, &(&1.level == :hard and &1.channel == :inbox))
    end

    test "invalid UTF-8 is removed and recorded" do
      assert {:ok, %{output: %{body: "ab"}, changes: [%{rule: :invalid_utf8, field: "body"}]}} =
               Inbox.render(%{"body" => <<"a", 0xFF, "b">>})
    end
  end

  describe "TP-24 webhook" do
    test "a JSON object or array is accepted and sent as rendered" do
      body = ~s({"order": "1234", "items": [1, 2]})

      assert {:ok, %{output: %{body: ^body, data: %{"order" => "1234"}}, changes: []}} =
               Webhook.render(body)

      assert {:ok, _result} = Webhook.render("[]")
    end

    test "invalid JSON and scalars are hard findings" do
      assert {:error, [%{check: :webhook_json, level: :hard, detail: %{position: _}}]} =
               Webhook.render(~s({"order": 1234,}))

      assert {:error, [%{check: :webhook_body_type}]} = Webhook.render(~s("text"))
      assert {:error, [%{check: :webhook_json}]} = Webhook.render(<<"{\"a\": \"", 0xFF, "\"}">>)
    end
  end
end
