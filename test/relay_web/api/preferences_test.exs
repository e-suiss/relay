defmodule RelayWeb.Api.PreferencesTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    :ok = F.category!(token, "orders", "transactional")
    category = %{"key" => "receipts", "name" => "Receipts", "message_class" => "transactional"}
    F.body(F.request(:post, "/v1/categories", token, Map.put(category, "locked", true)), 201)
    external_id = "user-" <> TenantFixture.random()
    F.body(F.request(:post, "/v1/subscribers", token, %{"external_id" => external_id}), 201)
    app = FakeAccess.client!(scope, ["read"])

    %{
      tenant: tenant,
      scope: scope,
      token: token,
      external_id: external_id,
      path: "/v1/subscribers/#{external_id}/preferences",
      app: app
    }
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp write(level, fields, value),
    do: Map.merge(%{"level" => level, "value" => value}, fields)

  defp cc(category, channel, value),
    do: write("category_channel", %{"category" => category, "channel" => channel}, value)

  defp cell(body, category, channel),
    do: Enum.find(body["cells"], &(&1["category"] == category and &1["channel"] == channel))

  defp patch(ctx, writes, headers \\ []),
    do: F.request(:patch, ctx.path, ctx.token, %{"preferences" => writes}, headers)

  defp subscriber!(ctx, sub \\ "pairwise-" <> FakeAccess.random()) do
    token = FakeAccess.user_token(ctx.tenant.attrs.access_tenant_id, ctx.app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type
    }

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    body = F.body(conn, 200)
    {:ok, id} = Relay.ExternalId.decode(body["subscriber_id"], ["sub"])
    %{token: body["access_token"], id: id, external_id: body["subscriber_id"], sub: sub}
  end

  defp mine(subscriber, method \\ :get, body \\ nil, headers \\ []),
    do: F.request(method, "/v1/subscriber/preferences", subscriber.token, body, headers)

  describe "PC-57 PC-12 server preferences" do
    test "PC-12: every active category other than system has a defined cell for every channel",
         ctx do
      body = F.body(F.request(:get, ctx.path, ctx.token), 200)

      assert body["object"] == "subscriber_preferences"
      assert "sub_" <> _ = body["subscriber_id"]
      assert body["channels"] == []
      assert body["workflows"] == []
      assert body["scope_keys"] == []

      assert body["profile"] == %{
               "quiet_hours" => [],
               "schedule" => [],
               "dnd_until" => nil,
               "quiet_hours_email" => false,
               "digest" => %{}
             }

      categories = body["cells"] |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort()
      assert categories == ["orders", "receipts"]

      assert %{"value" => "unset", "effective" => true, "source" => "class_default"} =
               cell(body, "orders", "email")

      assert %{"value" => "unset", "effective" => false} = cell(body, "orders", "whatsapp")
      assert %{"source" => "locked", "effective" => true} = cell(body, "receipts", "email")
    end

    test "PC-15: a tenant writes opt_out and nothing else", ctx do
      body = F.body(patch(ctx, [cc("orders", "email", "opt_out")]), 200)

      assert %{"value" => "opt_out", "effective" => false, "source" => "tenant"} =
               cell(body, "orders", "email")

      for value <- ["opt_in", "unset"] do
        assert code(patch(ctx, [cc("orders", "email", value)]), 422) ==
                 "preference_direction_forbidden"
      end

      body = F.body(F.request(:get, ctx.path, ctx.token), 200)
      assert cell(body, "orders", "email")["value"] == "opt_out"
    end

    test "PC-57, PC-16: channel, workflow and scope key switches are listed beside the cells",
         ctx do
      writes = [
        write("channel", %{"channel" => "sms"}, "opt_out"),
        write("workflow", %{"workflow" => "order-shipped"}, "opt_out"),
        write("scope_key", %{"scope_key" => "project-7"}, "opt_out")
      ]

      body = F.body(patch(ctx, writes), 200)
      assert body["channels"] == [%{"channel" => "sms", "value" => "opt_out"}]
      assert body["workflows"] == [%{"workflow" => "order-shipped", "value" => "opt_out"}]
      assert body["scope_keys"] == [%{"scope_key" => "project-7", "value" => "opt_out"}]
      assert %{"effective" => false, "source" => "user"} = cell(body, "orders", "sms")
    end

    test "PC-6: closing the last open channel of a locked category is refused, writing nothing",
         ctx do
      writes = for channel <- ~w(push email sms in_app), do: cc("receipts", channel, "opt_out")

      assert code(patch(ctx, writes), 422) == "preference_last_channel"
      body = F.body(F.request(:get, ctx.path, ctx.token), 200)
      assert cell(body, "receipts", "push")["value"] == "unset"

      F.body(patch(ctx, Enum.take(writes, 3)), 200)
      assert code(patch(ctx, Enum.drop(writes, 3)), 422) == "preference_last_channel"
      body = F.body(F.request(:get, ctx.path, ctx.token), 200)
      assert cell(body, "receipts", "in_app")["effective"] == true
    end

    test "PC-57: a write names what its level needs; an unknown category or subscriber is 404",
         ctx do
      missing = write("category_channel", %{"category" => "orders"}, "opt_out")
      problem = F.body(patch(ctx, [missing]), 422)
      assert problem["code"] == "validation_failed"
      assert [%{"pointer" => "/preferences/0/channel", "code" => "required"}] = problem["errors"]

      extra = write("channel", %{"channel" => "sms", "category" => "orders"}, "opt_out")
      problem = F.body(patch(ctx, [extra]), 422)

      assert [%{"pointer" => "/preferences/0/category", "code" => "not_allowed"}] =
               problem["errors"]

      assert code(patch(ctx, [cc("none", "sms", "opt_out")]), 404) == "category_not_found"

      path = "/v1/subscribers/nobody-#{TenantFixture.random()}/preferences"
      assert code(F.request(:get, path, ctx.token), 404) == "subscriber_not_found"
      off = write("channel", %{"channel" => "sms"}, "opt_out")

      assert code(F.request(:patch, path, ctx.token, %{"preferences" => [off]}), 404) ==
               "subscriber_not_found"
    end

    test "API-10: a repeated write replays its answer", ctx do
      key = F.key()
      off = write("channel", %{"channel" => "push"}, "opt_out")
      first = F.body(patch(ctx, [off], [key]), 200)
      again = patch(ctx, [off], [key])

      assert again.status == 200
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
      assert Jason.decode!(again.resp_body) == first
    end

    test "API-79: reading needs read or subscribers and writing needs subscribers", ctx do
      reader = F.token(ctx.scope, ["read"])
      assert F.body(F.request(:get, ctx.path, reader), 200)["object"] == "subscriber_preferences"
      off = write("channel", %{"channel" => "push"}, "opt_out")

      assert code(F.request(:patch, ctx.path, reader, %{"preferences" => [off]}), 403) ==
               "auth_insufficient_scope"
    end
  end

  describe "PC-59 consent copy" do
    test "PC-59, PC-21: the current consent of each brand and channel is listed, revoked first",
         ctx do
      {:ok, id} = Relay.Subscribers.locate(ctx.scope, ctx.external_id)
      brand = TenantFixture.subtenant!(ctx.scope)

      consent = fn attrs ->
        base = %{
          recipient_id: id,
          brand_subtenant_id: nil,
          channel: "email",
          status: "pending",
          consent_kind: nil,
          recipient_type: nil,
          source: "access",
          sequence: 1,
          occurred_at: DateTime.utc_now(),
          text_version_digest: nil,
          evidence: nil,
          iys_transaction_ref: nil,
          source_event_ref: "evt_" <> TenantFixture.random()
        }

        {:ok, result} = Relay.Preferences.record_consent(ctx.scope, Map.merge(base, attrs))
        result
      end

      assert consent.(%{}) == :recorded
      assert consent.(%{source: "iys", status: "revoked"}) == :recorded
      branded = %{brand_subtenant_id: brand, channel: "sms", status: "revoked"}
      assert consent.(branded) == :recorded

      path = "/v1/subscribers/#{ctx.external_id}/consents"
      body = F.body(F.request(:get, path, ctx.token), 200)
      assert length(body["data"]) == 2
      email = Enum.find(body["data"], &(&1["channel"] == "email"))
      assert %{"object" => "consent", "status" => "revoked", "source" => "iys"} = email
      assert email["brand"] == nil
      sms = Enum.find(body["data"], &(&1["channel"] == "sms"))
      assert sms["brand"] == Relay.ExternalId.encode("stn", brand)
      assert "cns_" <> _ = sms["id"]

      path = "/v1/subscribers/nobody-#{TenantFixture.random()}/consents"
      assert code(F.request(:get, path, ctx.token), 404) == "subscriber_not_found"
    end
  end

  describe "PC-57 API-45 subscriber preferences" do
    test "API-45, PC-57: the subscriber reads its own preferences with its token", ctx do
      subscriber = subscriber!(ctx)
      body = F.body(mine(subscriber), 200)

      assert body["subscriber_id"] == subscriber.external_id
      assert cell(body, "orders", "email")["value"] == "unset"

      assert code(F.request(:get, "/v1/subscriber/preferences", ctx.token), 401) ==
               "auth_invalid_token"
    end

    test "PC-57: the subscriber writes any value and its profile in one request", ctx do
      subscriber = subscriber!(ctx)
      F.body(F.request(:post, "/v1/categories", ctx.token, social("friends")), 201)

      body = %{
        "preferences" => [
          cc("orders", "whatsapp", "opt_in"),
          write("channel", %{"channel" => "sms"}, "opt_out")
        ],
        "profile" => %{
          "quiet_hours" => [%{"day" => "mon", "start" => "22:00", "end" => "07:00"}],
          "quiet_hours_email" => true,
          "dnd_until" => "2031-01-01T00:00:00Z",
          "digest" => %{"friends" => "digest"}
        }
      }

      shown = F.body(mine(subscriber, :patch, body), 200)
      assert %{"value" => "opt_in", "effective" => true} = cell(shown, "orders", "whatsapp")
      assert shown["channels"] == [%{"channel" => "sms", "value" => "opt_out"}]

      assert [%{"day" => "mon", "start" => "22:00", "end" => "07:00"}] =
               shown["profile"]["quiet_hours"]

      assert shown["profile"]["quiet_hours_email"] == true
      assert shown["profile"]["digest"] == %{"friends" => "digest"}
      assert shown["profile"]["schedule"] == []

      unset = %{"preferences" => [cc("orders", "whatsapp", "unset")]}
      again = F.body(mine(subscriber, :patch, unset), 200)
      assert cell(again, "orders", "whatsapp")["value"] == "unset"
      assert again["profile"]["digest"] == %{"friends" => "digest"}
    end

    test "PC-57: a digest outside social and digest-allowed operational categories is refused",
         ctx do
      subscriber = subscriber!(ctx)
      body = %{"profile" => %{"digest" => %{"orders" => "digest"}}}

      assert code(mine(subscriber, :patch, body), 422) == "preference_digest_not_allowed"
      assert F.body(mine(subscriber), 200)["profile"]["digest"] == %{}

      empty = [%{"day" => "mon", "start" => "09:00", "end" => "09:00"}]

      assert code(mine(subscriber, :patch, %{"profile" => %{"quiet_hours" => empty}}), 422) ==
               "validation_failed"
    end

    test "PC-6: the subscriber cannot close the last open channel of a locked category either",
         ctx do
      subscriber = subscriber!(ctx)

      writes = for channel <- ~w(push email sms in_app), do: cc("receipts", channel, "opt_out")

      assert code(mine(subscriber, :patch, %{"preferences" => writes}), 422) ==
               "preference_last_channel"
    end

    test "API-10: each subscriber's idempotency keys are its own", ctx do
      first = subscriber!(ctx)
      second = subscriber!(ctx)
      key = F.key()
      off = %{"preferences" => [write("channel", %{"channel" => "push"}, "opt_out")]}

      one = F.body(mine(first, :patch, off, [key]), 200)
      two = mine(second, :patch, off, [key])

      assert F.body(two, 200)["subscriber_id"] == second.external_id
      assert get_resp_header(two, "idempotency-replayed") == []
      assert one["subscriber_id"] == first.external_id
    end

    test "TN-73: a suspended subscriber's token is refused with 403", ctx do
      subscriber = subscriber!(ctx)
      actor = TenantFixture.actor()
      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, subscriber.id, "abuse", actor)

      assert code(mine(subscriber), 403) == "auth_subscriber_suspended"
      off = %{"preferences" => [write("channel", %{"channel" => "push"}, "opt_out")]}
      assert code(mine(subscriber, :patch, off), 403) == "auth_subscriber_suspended"
    end
  end

  defp social(key), do: %{"key" => key, "name" => key, "message_class" => "social"}
end
