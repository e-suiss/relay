defmodule RelayWeb.PreferencePageTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Relay.Compliance.Refusals
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @endpoint RelayWeb.Endpoint
  @form "application/x-www-form-urlencoded"
  @prefix "relay.preference_page.v1:"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    F.category!(token, "orders", "transactional")
    F.category!(token, "comments", "social")
    F.category!(token, "news", "marketing")
    locked = %{"key" => "receipts", "name" => "Makbuzlar", "message_class" => "transactional"}
    F.body(F.request(:post, "/v1/categories", token, Map.put(locked, "locked", true)), 201)
    external_id = "user-" <> TenantFixture.random()

    body = %{
      "external_id" => external_id,
      "email" => "ayse@example.com",
      "locale" => "tr",
      "timezone" => "Europe/Istanbul"
    }

    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    {:ok, %{"_id" => recipient_id}} = Relay.Subscribers.fetch(scope, external_id)

    %{scope: scope, token: token, external_id: external_id, recipient_id: recipient_id}
  end

  defp configure(key, changes) do
    previous = Application.get_env(:relay, key, [])
    Application.put_env(:relay, key, Keyword.merge(previous, changes))
    on_exit(fn -> Application.put_env(:relay, key, previous) end)
  end

  defp mint(ctx) do
    path = "/v1/subscribers/#{ctx.external_id}/preference_page_links"
    F.body(F.request(:post, path, ctx.token), 201)
  end

  defp page_path(ctx) do
    %URI{path: path} = URI.parse(mint(ctx)["url"])
    path
  end

  defp form_post(path, fields) do
    build_conn()
    |> put_req_header("content-type", @form)
    |> post(path, URI.encode_query(fields))
  end

  defp prefs(ctx), do: F.body(F.request(:get, prefs_path(ctx), ctx.token), 200)

  defp prefs_path(ctx), do: "/v1/subscribers/#{ctx.external_id}/preferences"

  defp patch!(ctx, writes),
    do: F.body(F.request(:patch, prefs_path(ctx), ctx.token, %{"preferences" => writes}), 200)

  defp opt_out(category, channel) do
    %{
      "level" => "category_channel",
      "category" => category,
      "channel" => channel,
      "value" => "opt_out"
    }
  end

  defp set(category, channel, value),
    do: %{"action" => "set", "category" => category, "channel" => channel, "value" => value}

  defp unsubscribe_path(ctx) do
    to = %{recipient_id: ctx.recipient_id, category: "news", locale: "tr", root: "https://r.test"}
    {:ok, %{https: "https://r.test" <> path}} = Refusals.links(ctx.scope, to)
    path
  end

  defp api_cell(ctx, category, channel) do
    body = prefs(ctx)
    Enum.find(body["cells"], &(&1["category"] == category and &1["channel"] == channel))
  end

  defp parts(token) do
    [fields, signature] = String.split(token, ".")
    {Base.url_decode64!(fields, padding: false), Base.url_decode64!(signature, padding: false)}
  end

  defp part(binary), do: Base.url_encode64(binary, padding: false)

  defp forms(page), do: Regex.scan(~r/<form method="(get|post)">.*?<\/form>/s, page)

  defp form_for(page, category, channel) do
    Enum.find_value(forms(page), fn [form, _method] ->
      if form =~ ~s(name="category" value="#{category}") and
           form =~ ~s(name="channel" value="#{channel}"),
         do: form
    end)
  end

  describe "X-51 PC-18 the hosted preference page link" do
    test "X-51, PC-18, X-22: the server API mints a link on the self-explanatory path that opens the subscriber's page",
         ctx do
      minted = mint(ctx)

      assert minted["object"] == "preference_page_link"
      assert "sub_" <> _ = minted["subscriber_id"]
      assert %URI{path: "/bildirim-tercihleri/" <> token} = URI.parse(minted["url"])
      {:ok, expires_at, 0} = DateTime.from_iso8601(minted["expires_at"])
      lifetime = Relay.Limits.fetch!(["preference_page_link_lifetime_seconds"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), lifetime, 60

      conn = get(build_conn(), "/bildirim-tercihleri/" <> token)
      page = html_response(conn, 200)
      assert page =~ "<h1>Bildirim tercihleri</h1>"
      assert page =~ "Makbuzlar"
      refute page =~ "<script"
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"

      assert html_response(get(build_conn(), "/notification-preferences/" <> token), 200) =~
               "<html lang=\"tr\">"
    end

    test "X-51: the token opens only this page: a tampered, expired or unsubscribe token is refused",
         ctx do
      "/bildirim-tercihleri/" <> token = page_path(ctx)
      {fields, signature} = parts(token)

      changed = binary_part(fields, 0, byte_size(fields) - 1) <> "x"
      tampered = part(changed) <> "." <> part(signature)
      assert html_response(get(build_conn(), "/bildirim-tercihleri/" <> tampered), 404)

      <<head::binary-size(51), _expires::64, rest::binary>> = fields
      past = DateTime.to_unix(DateTime.utc_now()) - 60
      old = <<head::binary, past::64, rest::binary>>
      {:ok, old_signature} = Relay.Keys.sign(:es256, "preference-link", @prefix <> old)
      expired = part(old) <> "." <> part(old_signature)
      assert Relay.Preferences.verify_page_token(expired) == {:error, :expired}

      assert html_response(get(build_conn(), "/bildirim-tercihleri/" <> expired), 410) =~
               "This link has expired."

      "/abonelik-iptali/" <> unsubscribe = unsubscribe_path(ctx)
      assert html_response(get(build_conn(), "/bildirim-tercihleri/" <> unsubscribe), 404)
      assert {:error, :invalid} = Relay.Compliance.verify_unsubscribe_token(token)
      clear = %{"action" => "quiet_hours_clear"}
      assert form_post("/bildirim-tercihleri/" <> tampered, clear).status == 404
    end

    test "X-51, PC-36: the unsubscribe page leads to the recipient's hosted preference page",
         ctx do
      path = unsubscribe_path(ctx)

      page = html_response(form_post(path, %{"confirm" => "yes"}), 200)
      assert page =~ "Tercihlerimi yönet"
      [_all, href] = Regex.run(~r/href="([^"]+)"/, page)
      assert %URI{path: "/bildirim-tercihleri/" <> _token} = URI.parse(href)
    end
  end

  describe "X-51 X-18 the page renders the API cells" do
    test "X-22, PC-6, X-51: a locked category shows its label and beneficiary, and its last open channel has no switch",
         ctx do
      assert %{"locked" => true, "lock_beneficiary" => "tenant", "category_name" => "Makbuzlar"} =
               api_cell(ctx, "receipts", "email")

      assert %{"locked" => false, "lock_beneficiary" => nil} = api_cell(ctx, "orders", "email")
      path = page_path(ctx)
      page = html_response(get(build_conn(), path), 200)
      assert page =~ "Açık (kilitli)"
      assert page =~ "Hizmetin size sunulabilmesi için gerekli olduğundan kilitli."
      assert form_for(page, "receipts", "email")

      patch!(ctx, for(channel <- ~w(push email sms), do: opt_out("receipts", channel)))

      page = html_response(get(build_conn(), path), 200)
      assert page =~ "En az bir kanal açık kalır."
      refute form_for(page, "receipts", "in_app")

      off = set("receipts", "in_app", "opt_out")
      assert html_response(form_post(path, off), 422) =~ "Bu değişiklik uygulanamadı."
      assert api_cell(ctx, "receipts", "in_app")["effective"]
    end

    test "PC-15, X-51: a cell the tenant turned off says so and the page does not turn it on",
         ctx do
      patch!(ctx, [opt_out("orders", "sms")])

      assert %{"disabled_by_admin" => true, "effective" => false} = api_cell(ctx, "orders", "sms")
      path = page_path(ctx)
      page = html_response(get(build_conn(), path), 200)
      assert page =~ "Yöneticiniz kapattı"
      refute form_for(page, "orders", "sms")

      assert form_post(path, set("orders", "sms", "opt_in")).status == 422
      refute api_cell(ctx, "orders", "sms")["effective"]
    end

    test "X-20, X-51: a cell without a digest turns off and back on with one click each, with equal buttons",
         ctx do
      path = page_path(ctx)
      page = html_response(get(build_conn(), path), 200)
      off = form_for(page, "orders", "email")
      assert off =~ ~s(<form method="post">)
      assert off =~ ~s(<button type="submit" class="choice">Kapat</button>)

      fields = set("orders", "email", "opt_out")
      conn = form_post(path, fields)
      assert conn.status == 303
      assert [location] = get_resp_header(conn, "location")
      assert location == path <> "?saved=1"
      refute api_cell(ctx, "orders", "email")["effective"]

      page = html_response(get(build_conn(), location), 200)
      assert page =~ "Tercihleriniz kaydedildi."
      on = form_for(page, "orders", "email")
      assert on =~ ~s(<button type="submit" class="choice">Aç</button>)
      assert String.replace(on, ~w(opt_in Aç), "") == String.replace(off, ~w(opt_out Kapat), "")

      form_post(path, %{fields | "value" => "opt_in"})
      assert %{"effective" => true, "value" => "opt_in", "source" => "user"} =
               api_cell(ctx, "orders", "email")
    end

    test "PC-17, X-20, X-51: a digestible cell offers Anında al, Özet al and Hiç alma with none preselected",
         ctx do
      assert api_cell(ctx, "comments", "push")["digest_allowed"]
      refute api_cell(ctx, "orders", "push")["digest_allowed"]

      path = page_path(ctx)
      page = html_response(get(build_conn(), path), 200)
      step = form_for(page, "comments", "push")
      assert step =~ ~s(<form method="get">)

      query = URI.encode_query(%{"category" => "comments", "channel" => "push"})
      choices = html_response(get(build_conn(), path <> "?" <> query), 200)

      for {value, label} <- [{"instant", "Anında al"}, {"digest", "Özet al"}, {"none", "Hiç alma"}] do
        assert choices =~ ~s(class="choice" name="choice" value="#{value}">#{label}</button>)
      end

      refute choices =~ "checked"
      refute choices =~ "selected"
      refute choices =~ "autofocus"

      digest = %{"action" => "choose", "category" => "comments", "channel" => "push"}
      digest = Map.put(digest, "choice", "digest")
      assert form_post(path, digest).status == 303
      body = prefs(ctx)
      assert body["profile"]["digest"] == %{"comments" => "digest"}
      assert html_response(get(build_conn(), path), 200) =~ "Açık · özet"

      assert form_post(path, %{digest | "choice" => "none"}).status == 303
      assert %{"effective" => false, "value" => "opt_out"} = api_cell(ctx, "comments", "push")

      assert form_post(path, %{digest | "choice" => "instant"}).status == 303
      assert api_cell(ctx, "comments", "push")["effective"]

      assert form_post(path, set("comments", "push", "opt_out")).status == 422
    end

    test "X-44, X-21, PC-21: consents are shown read only from the consent copy with a link to Access",
         ctx do
      configure(RelayWeb.Links, consent_url: "https://access.example/consents")
      path = page_path(ctx)
      page = html_response(get(build_conn(), path), 200)

      link = ~s(<a rel="noreferrer" href="https://access.example/consents">İzin ver</a>)
      assert page =~ "İzin bekleniyor · " <> link
      assert page =~ "İzinlerimi yönet"
      assert page =~ "Kayıtlı izin yok."
      refute form_for(page, "news", "email")
      refute page =~ ~s(type="checkbox")
      refute page =~ ~s(type="radio")

      attrs = %{
        recipient_id: ctx.recipient_id,
        brand_subtenant_id: nil,
        channel: "email",
        status: "active",
        consent_kind: "explicit_opt_in",
        recipient_type: "individual",
        source: "access",
        sequence: 1,
        occurred_at: DateTime.utc_now(),
        text_version_digest: :crypto.hash(:sha256, "consent text v1"),
        evidence: %{"ip" => "203.0.113.9"},
        iys_transaction_ref: nil,
        source_event_ref: "evt_" <> TenantFixture.random()
      }

      {:ok, :recorded} = Relay.Preferences.record_consent(ctx.scope, attrs)
      page = html_response(get(build_conn(), path), 200)
      assert page =~ "E-posta: Verildi"
      assert form_for(page, "news", "email")
      assert form_for(page, "news", "sms") == nil
      assert form_for(page, "orders", "sms")
    end

    test "PC-16, X-51: a push cell is turned off in device settings when no device permits it",
         ctx do
      device = %{
        "platform" => "fcm",
        "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
        "app" => "com.example.shop",
        "permission" => "denied"
      }

      refute api_cell(ctx, "orders", "push")["disabled_in_device_settings"]
      devices = "/v1/subscribers/#{ctx.external_id}/devices"
      F.body(F.request(:post, devices, ctx.token, device), 201)

      assert %{"disabled_in_device_settings" => true, "effective" => true} =
               api_cell(ctx, "orders", "push")

      refute api_cell(ctx, "orders", "email")["disabled_in_device_settings"]
      page = html_response(get(build_conn(), page_path(ctx)), 200)
      assert page =~ "Cihaz ayarlarından kapalı"
      assert form_for(page, "orders", "push")
    end

    test "X-22, PC-12, PC-57 (5): channel switches, a row turned off and quiet hours are written as the subscriber's own",
         ctx do
      path = page_path(ctx)

      switch = %{"action" => "channel", "channel" => "sms", "value" => "opt_out"}
      assert form_post(path, switch).status == 303

      body = prefs(ctx)
      assert body["channels"] == [%{"channel" => "sms", "value" => "opt_out"}]
      assert html_response(get(build_conn(), path), 200) =~ "Tümü kapalı"

      assert form_post(path, %{"action" => "row_off", "category" => "orders"}).status == 303
      body = prefs(ctx)
      refute Enum.any?(body["cells"], &(&1["category"] == "orders" and &1["effective"]))
      assert form_post(path, %{"action" => "row_off", "category" => "receipts"}).status == 422

      quiet = %{"action" => "quiet_hours", "start" => "22:00", "end" => "07:30"}
      assert form_post(path, quiet).status == 303
      body = prefs(ctx)
      assert length(body["profile"]["quiet_hours"]) == 7
      assert form_post(path, %{quiet | "end" => "22:00"}).status == 422
      assert form_post(path, %{"action" => "quiet_hours_clear"}).status == 303
      assert form_post(path, %{"action" => "quiet_hours_email", "value" => "true"}).status == 303
      body = prefs(ctx)
      assert body["profile"]["quiet_hours"] == []
      assert body["profile"]["quiet_hours_email"] == true
      assert form_post(path, %{"action" => "unknown"}).status == 422
    end
  end
end
