defmodule Relay.Channels.WhatsappTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Whatsapp.Bundled
  alias Relay.Channels.Whatsapp.Errors
  alias Relay.Channels.Whatsapp.Limits
  alias Relay.Channels.Whatsapp.Message
  alias Relay.Channels.Whatsapp.Pricing
  alias Relay.Channels.Whatsapp.Status
  alias Relay.Channels.Whatsapp.Template
  alias Relay.Channels.Whatsapp.Webhook
  alias Relay.Channels.Whatsapp.Window

  @secret Relay.Redacted.wrap("app-secret")
  @now ~U[2026-11-05 12:00:00Z]

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp signed(body) do
    mac = :crypto.mac(:hmac, :sha256, "app-secret", body) |> Base.encode16(case: :lower)
    [{"x-hub-signature-256", "sha256=" <> mac}]
  end

  defp notification(field, value) do
    Jason.encode!(%{
      "object" => "whatsapp_business_account",
      "entry" => [%{"id" => "1022", "changes" => [%{"field" => field, "value" => value}]}]
    })
  end

  defp metadata, do: %{"display_phone_number" => "15550783881", "phone_number_id" => "1065"}

  defp preference(wa_id, value) do
    %{
      "wa_id" => wa_id,
      "category" => "marketing_messages",
      "value" => value,
      "timestamp" => 1_731_705_721
    }
  end

  defp rate(country, category, micros) do
    %{
      "country" => country,
      "market" => country || "Other",
      "category" => category,
      "unit_price_micros" => micros
    }
  end

  describe "CH-57 CH-60 message body" do
    test "CH-57: a rendered cell is a template message with positional parameters in number order" do
      content = %{
        "template_name" => "order_shipped_v3",
        "language" => "tr",
        "parameters" => [%{"name" => "2", "value" => "B"}, %{"name" => "1", "value" => "A"}]
      }

      assert {:ok, body} = Message.body(content, "+905551112233", "rly1.x.1")
      assert body["type"] == "template"
      assert body["to"] == "+905551112233"
      assert body["biz_opaque_callback_data"] == "rly1.x.1"
      assert body["template"]["name"] == "order_shipped_v3"
      assert body["template"]["language"] == %{"code" => "tr"}

      assert [%{"type" => "body", "parameters" => [%{"text" => "A"}, %{"text" => "B"}]}] =
               body["template"]["components"]
    end

    test "CH-57: named parameters carry their names, a locale becomes a Meta code and mixed names are refused" do
      content = %{
        "template_name" => "welcome_v1",
        "language" => "en-US",
        "parameters" => [%{"name" => "first_name", "value" => "Ada"}]
      }

      assert {:ok, body} = Message.body(content, "+1", "c")
      assert body["template"]["language"] == %{"code" => "en_US"}

      assert [%{"parameters" => [%{"parameter_name" => "first_name", "text" => "Ada"}]}] =
               body["template"]["components"]

      parameters = [%{"name" => "1", "value" => "a"}, %{"name" => "x", "value" => "b"}]
      mixed = %{content | "parameters" => parameters}
      assert Message.body(mixed, "+1", "c") == {:error, :invalid_content}
      assert Message.body(%{}, "+1", "c") == {:error, :invalid_content}
    end

    test "CH-58: free-form text is sent only as the chosen kind; without a choice the template goes" do
      content = %{"template_name" => "t_v1", "language" => "tr", "text" => "Merhaba"}
      assert Message.kinds(content) == [:template, :free_form]
      assert {:ok, %{"type" => "template"}} = Message.body(content, "+1", "c")

      assert {:ok, %{"type" => "text", "text" => %{"body" => "Merhaba"}}} =
               Message.body(Map.put(content, "kind", "free_form"), "+1", "c")
    end

    test "CH-60: the correlation names the delivery and the attempt and nothing else is read back" do
      id = Relay.Id.generate()
      correlation = Message.correlation(id, 3)
      assert Message.parse_correlation(correlation) == {:ok, id, 3}
      assert Message.parse_correlation("tenant-data") == :error
      assert Message.parse_correlation(nil) == :error
    end
  end

  describe "CH-58 customer service window" do
    test "CH-58: an inbound message opens the window for 24 hours and a late one never shortens it" do
      state = Window.refresh(nil, ~U[2026-11-05 10:00:00Z])
      assert Window.open?(state, @now)
      refute Window.open?(state, ~U[2026-11-06 10:00:00Z])
      assert Window.refresh(state, ~U[2026-11-05 09:00:00Z]) == state
      assert Window.closes_at(state, @now) == ~U[2026-11-06 10:00:00.000Z]
      refute Window.open?(nil, @now)
    end

    test "CH-58: free-form only in an open window, the template otherwise, free-form alone into a closed window is refused" do
      assert Window.choose(true, [:template, :free_form]) == {:ok, :free_form}
      assert Window.choose(false, [:template, :free_form]) == {:ok, :template}
      assert Window.choose(false, [:free_form]) == {:error, :window_closed}
      assert Window.choose(true, []) == {:error, :no_content}
    end
  end

  describe "CH-59 error rules" do
    test "CH-59: every code of the spec table maps to its class" do
      declarations = declarations()

      for {code, class} <- [
            {"131026", "permanent_target"},
            {"131050", "policy"},
            {"131049", "policy"},
            {"130429", "transient"},
            {"131056", "transient"},
            {"132015", "quota"},
            {"135000", "quota"},
            {"131042", "sender_config"}
          ] do
        assert %{"class" => ^class} =
                 ChannelDeclarations.expectation(declarations, "whatsapp_cloud", code),
               code
      end

      assert %{"condition" => "pair_rate_limited"} =
               ChannelDeclarations.expectation(declarations, "whatsapp_cloud", "131056")

      assert %{"condition" => "window_closed"} =
               ChannelDeclarations.expectation(declarations, "whatsapp_cloud", "131047")

      assert %{"class" => "unknown"} =
               ChannelDeclarations.expectation(declarations, "whatsapp_cloud", "424242")
    end

    test "CH-59: the follow-ups of the codes" do
      assert Errors.follow_up("131026") == :never_retry
      assert Errors.follow_up("131050") == :never_retry
      assert Errors.follow_up("131049") == {:not_before_ms, 86_400_000}
      assert Errors.follow_up("131047") == :replan_with_template
      assert Errors.follow_up("130429") == :slow_number
      assert Errors.follow_up("131056") == :slow_pair
      assert Errors.follow_up("131057") == :number_unavailable
      assert Errors.follow_up("100") == :none
      assert Errors.opt_out?("131050")
      refute Errors.opt_out?("131049")
    end

    test "CH-59, T-28: a WhatsApp attempt whose answer never came is not sent again" do
      {:ok, declaration} = ChannelDeclarations.declaration(declarations(), "whatsapp_cloud")
      policy = declaration["provider_idempotency_policy"]

      assert policy["correlation_field"] == "biz_opaque_callback_data"
      assert ChannelDeclarations.paid?(declaration, "whatsapp")
      assert Relay.Channels.uncertain(policy, true, false) == {:stop, :uncertain}
    end
  end

  describe "CH-60 webhooks" do
    test "CH-60, T-40: the signature is checked on the raw body before parsing" do
      body = notification("messages", %{"metadata" => metadata(), "statuses" => []})
      assert Webhook.verify(@secret, body, signed(body)) == :ok
      assert Webhook.verify(@secret, body <> " ", signed(body)) == {:error, :bad_signature}
      assert Webhook.verify(@secret, body, []) == {:error, :missing_header}
    end

    test "CH-60: statuses are normalized with their dedup key, correlation and whole pricing object" do
      id = Relay.Id.generate()
      pricing = %{"billable" => true, "category" => "utility", "type" => "regular"}

      status = %{
        "id" => "wamid.A",
        "status" => "delivered",
        "timestamp" => "1762344000",
        "recipient_id" => "905551112233",
        "biz_opaque_callback_data" => Message.correlation(id, 1),
        "pricing" => pricing
      }

      failed = %{
        "id" => "wamid.B",
        "status" => "failed",
        "timestamp" => 1_762_344_001,
        "errors" => [%{"code" => 131_026, "title" => "Message undeliverable"}]
      }

      body = notification("messages", %{"metadata" => metadata(), "statuses" => [status, failed]})
      assert {:ok, [{:status, number, delivered}, {:status, _, failure}]} = Webhook.parse(body)

      assert number.phone_number_id == "1065"
      assert delivered.dedup_key == "wamid.A:delivered:1762344000"
      assert delivered.correlation == {id, 1}
      assert delivered.pricing == pricing
      assert delivered.event_code == "delivered"
      assert failure.raw_code == "131026"
      assert failure.correlation == nil
    end

    test "CH-60: transitions are monotonic and a failure after delivery is a conflict" do
      assert Status.transition(nil, "sent") == :apply
      assert Status.transition("sent", "delivered") == :apply
      assert Status.transition("read", "delivered") == :stale
      assert Status.transition("delivered", "sent") == :stale
      assert Status.transition("delivered", "failed") == :conflict
      assert Status.transition("sent", "failed") == :apply
      assert Status.ordering("sent") == :wait
      assert Status.ordering("delivered") == :ready
    end

    test "CH-58, CH-57, CH-61, PC-43: inbound messages, template changes, account updates, preferences and limits are parsed" do
      inbound =
        notification("messages", %{
          "metadata" => metadata(),
          "messages" => [
            %{"from" => "905551112233", "id" => "wamid.C", "timestamp" => "1762344000"}
          ]
        })

      assert {:ok, [{:inbound, %{wa_id: "905551112233", phone_number_id: "1065"}}]} =
               Webhook.parse(inbound)

      template =
        notification("message_template_status_update", %{
          "event" => "REJECTED",
          "message_template_id" => 12_345,
          "message_template_name" => "order_shipped_v3",
          "message_template_language" => "tr",
          "reason" => "INCORRECT_CATEGORY"
        })

      assert {:ok, [{:template_status, %{template_id: "12345", reason: "INCORRECT_CATEGORY"}}]} =
               Webhook.parse(template)

      category =
        notification("template_category_update", %{
          "message_template_name" => "order_shipped_v3",
          "message_template_language" => "tr",
          "previous_category" => "UTILITY",
          "new_category" => "MARKETING"
        })

      assert {:ok, [{:template_category, change}]} = Webhook.parse(category)
      assert %{new_category: "marketing", previous_category: "utility"} = change

      account =
        notification("account_update", %{
          "event" => "ACCOUNT_VIOLATION",
          "violation_info" => %{"violation_type" => "SCAM"}
        })

      assert {:ok, [{:account_update, %{violation_type: "SCAM"}}]} = Webhook.parse(account)

      preferences =
        notification("user_preferences", %{
          "metadata" => metadata(),
          "user_preferences" => [
            preference("905551112233", "stop"),
            preference("905551112234", "resume")
          ]
        })

      assert {:ok, [{:user_preference, %{value: :stop}}, {:user_preference, %{value: :resume}}]} =
               Webhook.parse(preferences)

      upgrade =
        notification("phone_number_quality_update", %{
          "event" => "THROUGHPUT_UPGRADE",
          "max_daily_conversations_per_business" => "TIER_UNLIMITED"
        })

      assert {:ok, [{:messaging_limit, limit}]} = Webhook.parse(upgrade)
      assert %{event: "THROUGHPUT_UPGRADE", limit: "TIER_UNLIMITED"} = limit

      assert {:ok, [{:ignored, "flows"}]} = Webhook.parse(notification("flows", %{}))
      assert Webhook.parse("{}") == {:error, :invalid_body}
    end

    test "CH-60: the subscription check answers only the matching token" do
      params = %{"hub.mode" => "subscribe", "hub.verify_token" => "t", "hub.challenge" => "42"}
      assert Webhook.challenge(params, Relay.Redacted.wrap("t")) == {:ok, "42"}
      assert Webhook.challenge(params, Relay.Redacted.wrap("u")) == :error
      assert Webhook.challenge(%{}, Relay.Redacted.wrap("t")) == :error
    end
  end

  describe "CH-57 TP-23 template lifecycle" do
    test "TP-23: Meta statuses move the Relay state and only an approved template is sendable" do
      assert Template.transition("pending_approval", "APPROVED") == "approved"
      assert Template.transition("approved", "PAUSED") == "paused"
      assert Template.transition("paused", "REINSTATED") == "approved"
      assert Template.transition("pending_approval", "REJECTED") == "rejected"
      assert Template.transition("approved", "DISABLED") == "disabled"
      assert Template.transition("approved", "FLAGGED") == "approved"

      assert Template.sendable?("approved")

      for status <- ~w(pending_approval rejected paused disabled),
          do: refute(Template.sendable?(status))
    end

    test "CH-57: the class maps to a fixed category and Meta's change is a drift" do
      assert Template.category("security") == {:ok, "authentication"}
      assert Template.category("action_required") == {:ok, "utility"}
      assert Template.category("social") == {:ok, "marketing"}
      assert Template.category("system") == {:error, :unknown_class}

      assert Template.drift("utility", "utility") == :none
      assert Template.drift("utility", nil) == :none

      assert {:drift, %{expected: "utility", actual: "marketing", cost_up?: true}} =
               Template.drift("utility", "marketing")
    end

    test "TP-23: the edit quota says how many edits remain and when the next one opens" do
      limits = %{"per_24h" => 1, "per_30d" => 10}
      assert %{remaining: 10, next_at: nil, reason: nil} = Template.edit_quota([], limits, @now)

      daily = Template.edit_quota([~U[2026-11-05 08:00:00Z]], limits, @now)
      assert daily.reason == :daily
      assert DateTime.compare(daily.next_at, ~U[2026-11-06 08:00:00Z]) == :eq

      month = for day <- 1..10, do: DateTime.add(~U[2026-10-10 00:00:00Z], day, :day)
      assert %{reason: :monthly, remaining: 0} = Template.edit_quota(month, limits, @now)
    end

    test "TP-23: the preview shows the approved text with the parameters and flags divergence" do
      components = [
        %{"type" => "HEADER", "text" => "Order {{1}}"},
        %{"type" => "BODY", "text" => "Hello {{1}}, your order ships {{2}}."},
        %{"type" => "FOOTER", "text" => "Thanks"}
      ]

      parameters = [%{"name" => "1", "value" => "Ada"}, %{"name" => "3", "value" => "x"}]
      preview = Template.preview(components, parameters)
      assert preview.header == "Order Ada"
      assert preview.body == "Hello Ada, your order ships {{2}}."
      assert preview.footer == "Thanks"
      assert preview.missing == ["2"]
      assert preview.extra == ["3"]
      assert Template.digest(components) == Template.digest(components)
    end
  end

  describe "CH-61 CH-18 limits and pricing" do
    test "CH-61: tiers, the default tier and the 90 percent warning" do
      limits = Bundled.content("whatsapp_messaging_limits")
      assert Limits.tier_limit(limits, "TIER_2K") == 2000
      assert Limits.tier_limit(limits, "TIER_UNLIMITED") == :unlimited
      assert Limits.tier_limit(limits, "10000") == 10_000
      assert Limits.tier_limit(limits, nil) == 250
      assert Limits.warn?(limits, 224, 225, 250)
      refute Limits.warn?(limits, 225, 226, 250)
      refute Limits.warn?(limits, 1, 2, :unlimited)
      assert Limits.counts?(false)
      refute Limits.counts?(true)
      assert Limits.unavailable_ms(limits) == 60_000
    end

    test "CH-58, CH-60: a missing price is unknown, never free, and a free pricing type is zero" do
      card = %{
        "rates" => [
          rate("TR", "utility", 5300),
          rate(nil, "utility", 8000)
        ]
      }

      assert Pricing.price(card, "TR", "utility") == {:ok, 5300}
      assert Pricing.price(card, "TR", "marketing") == :unknown
      assert Pricing.price(card, "DE", "utility") == {:ok, 8000}
      assert Pricing.price(card, "TR", "service") == :unknown
      free = %{"type" => "free_customer_service", "category" => "service"}
      billed = %{"type" => "regular", "category" => "UTILITY"}
      assert Pricing.cost(card, free, "TR") == {:ok, 0}
      assert Pricing.cost(card, billed, "TR") == {:ok, 5300}
      assert Pricing.cost(card, nil, "TR") == :unknown
    end

    test "CH-18: a rate card applies from the start of its quarter" do
      assert Pricing.quarter(~D[2026-11-05]) == ~D[2026-10-01]
      cards = [%{"effective_from" => "2026-07-01"}, %{"effective_from" => "2026-10-01"}]
      assert Pricing.card(cards, ~D[2026-09-30]) == {:ok, %{"effective_from" => "2026-07-01"}}
      assert Pricing.card(cards, ~D[2026-11-05]) == {:ok, %{"effective_from" => "2026-10-01"}}
      assert Pricing.card(cards, ~D[2026-01-01]) == :none
      assert [%{"currency" => "USD"} | _] = Bundled.rate_cards()
    end
  end
end
