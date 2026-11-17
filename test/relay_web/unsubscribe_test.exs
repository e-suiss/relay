defmodule RelayWeb.UnsubscribeTest.Sink do
  @behaviour Relay.Compliance.RefusalSink

  @impl Relay.Compliance.RefusalSink
  def refused(scope, notice) do
    send(:persistent_term.get(__MODULE__), {:refused, scope, notice})
    :ok
  end
end

defmodule RelayWeb.UnsubscribeTest.OutsideIys do
  @behaviour Relay.Policy.IysGate

  @impl Relay.Policy.IysGate
  def status(_scope, _brand, _channel, _address_digest), do: :out_of_scope
end

defmodule RelayWeb.UnsubscribeTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Relay.Channels.Live.Unsubscribe
  alias Relay.Compliance.Refusals
  alias Relay.Compliance.Refusals.SinkWorker
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @endpoint RelayWeb.Endpoint
  @form "application/x-www-form-urlencoded"
  @root "https://relay.test"
  @one_click "List-Unsubscribe=One-Click"

  @preferences "SELECT key, channel::text, value, updated_by FROM relay.preferences WHERE recipient_id = $1 ORDER BY key"
  @refusals "SELECT source, scope, category_key, evidence_ct IS NOT NULL FROM relay.refusals WHERE recipient_id = $1 ORDER BY created_at, id"
  @consents "SELECT status, writer, source, evidence_ct IS NOT NULL FROM relay.consents WHERE recipient_id = $1 ORDER BY created_at, id"
  @suppressions "SELECT reason FROM relay.suppressions WHERE channel = 'email' ORDER BY created_at, id"
  @back "SELECT result FROM relay_fn.preference_set($1, $2, 'category_channel', 'news', 'email', 'opt_in', 'subscriber', 'acc_user_1')"
  @evidence "SELECT evidence_ct FROM relay.refusals WHERE recipient_id = $1"
  @gates ~w(consent.missing consent.revoked consent.expired preference.category_channel)

  setup do
    gate = Application.get_env(:relay, Relay.Policy.IysGate)
    Application.put_env(:relay, Relay.Policy.IysGate, impl: __MODULE__.OutsideIys)

    on_exit(fn ->
      if gate,
        do: Application.put_env(:relay, Relay.Policy.IysGate, gate),
        else: Application.delete_env(:relay, Relay.Policy.IysGate)
    end)

    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    F.category!(token, "news", "marketing")
    F.category!(token, "deals", "marketing")
    F.category!(token, "orders", "transactional")
    {external_id, recipient_id} = subscriber!(scope, token, "tr")

    %{scope: scope, token: token, external_id: external_id, recipient_id: recipient_id}
  end

  defp subscriber!(scope, token, locale) do
    external_id = "user-" <> TenantFixture.random()

    body = %{
      "external_id" => external_id,
      "email" => "ayse@example.com",
      "locale" => locale,
      "timezone" => "Europe/Istanbul"
    }

    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    {:ok, %{"_id" => recipient_id}} = Relay.Subscribers.fetch(scope, external_id)
    {external_id, recipient_id}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp links!(ctx, category, locale \\ "tr") do
    to = %{recipient_id: ctx.recipient_id, category: category, locale: locale, root: @root}
    {:ok, links} = Refusals.links(ctx.scope, to)
    links
  end

  defp path!(ctx, category \\ "news") do
    %{https: @root <> path} = links!(ctx, category)
    path
  end

  defp link_token(path), do: path |> String.split("/") |> List.last()

  defp form_post(path, body) do
    build_conn()
    |> put_req_header("content-type", @form)
    |> put_req_header("user-agent", "Mail/1.0")
    |> post(path, body)
  end

  defp consent!(ctx) do
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
  end

  defp delivery!(ctx, workflow) do
    body = %{"workflow" => workflow, "to" => [ctx.external_id], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    delivery
  end

  defp consents(ctx), do: sql!(ctx.scope, @consents, [ctx.recipient_id])

  defp refuse(ctx, attrs), do: Relay.Compliance.refuse(ctx.scope, attrs)

  defp configure(key, changes) do
    previous = Application.get_env(:relay, key, [])
    Application.put_env(:relay, key, Keyword.merge(previous, changes))
    on_exit(fn -> Application.put_env(:relay, key, previous) end)
  end

  describe "PC-35 the one-click endpoint" do
    test "PC-35, CH-38: a bulk e-mail gets an HTTPS one-click URI and a mailto URI", ctx do
      links = links!(ctx, "news")

      assert @root <> "/abonelik-iptali/" <> token = links.https
      assert links.mailto == "mailto:unsubscribe@localhost?subject=unsubscribe:" <> token
      assert %{https: @root <> "/unsubscribe/" <> _token} = links!(ctx, "news", "en")
      assert {:ok, link} = Refusals.describe_link(token)
      assert link == %{state: :open, locale: "tr", category: "news"}

      headers =
        Relay.Channels.Email.Headers.build(%{
          class: "marketing",
          return_path: "b-1@bounce.example.com",
          feedback_id: %{campaign: "news", category: "news", tenant: "t", sender: "s"},
          unsubscribe: links
        })

      assert {:ok, %{headers: fields, dkim_headers: signed}} = headers
      assert {"List-Unsubscribe", "<" <> links.https <> ">, <" <> links.mailto <> ">"} in fields
      assert {"List-Unsubscribe-Post", @one_click} in fields
      assert "list-unsubscribe" in signed
      assert "list-unsubscribe-post" in signed
    end

    test "PC-35, CH-38: only an e-mail of the bulk stream is given the URIs", ctx do
      content = Jason.encode!(%{"subject" => "News", "text" => "News inside"})

      delivery = %{
        "channel" => "email",
        "message_class" => "marketing",
        "recipient_id" => ctx.recipient_id,
        "category_key" => "news",
        "subtenant_id" => nil,
        "locale" => "tr"
      }

      assert {:ok, filled} = Unsubscribe.fill(ctx.scope, delivery, content)
      assert %{"unsubscribe" => %{"https" => https, "mailto" => mailto}} = Jason.decode!(filled)
      assert "https://" <> _rest = https
      assert https =~ "/abonelik-iptali/"
      assert "mailto:" <> _address = mailto

      plain = %{delivery | "message_class" => "transactional", "category_key" => "orders"}
      assert {:ok, ^content} = Unsubscribe.fill(ctx.scope, plain, content)
    end

    test "PC-35: GET shows the page and changes no state", ctx do
      path = path!(ctx)
      conn = get(build_conn(), path)

      assert html_response(conn, 200) =~ ~s(name="confirm" value="yes")
      assert html_response(conn, 200) =~ ~s(<html lang="tr">)
      assert get_resp_header(conn, "location") == []
      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == []
      assert OutboxEvents.data(ctx.scope, "subscription.unsubscribed") == []
    end

    test "PC-35, INV-18: a one-click POST takes the recipient out of that message's category as a preference",
         ctx do
      path = path!(ctx)
      conn = form_post(path, @one_click)

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "location") == []

      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) ==
               [["news", "email", "opt_out", "unsubscribe"]]

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) ==
               [["rfc8058", "category", "news", true]]

      assert sql!(ctx.scope, @consents, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @suppressions, []) == []
      assert F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id") == []

      assert [event] = OutboxEvents.data(ctx.scope, "subscription.unsubscribed")
      assert %{"channel" => "email", "category" => "news"} = event
      assert "sub_" <> _id = event["recipient_id"]
      assert [changed] = OutboxEvents.data(ctx.scope, "preference.changed")
      assert %{"level" => "category_channel", "value" => "opt_out"} = changed
      assert OutboxEvents.data(ctx.scope, "consent.revoked") == []
      assert {:ok, %{state: :unsubscribed}} = Refusals.describe_link(link_token(path))
    end

    test "PC-35: the evidence holds the time, the address, the user agent and the source, sealed",
         ctx do
      assert response(form_post(path!(ctx), @one_click), 200) == ""

      [[ct]] = sql!(ctx.scope, @evidence, [ctx.recipient_id])

      field = %{
        tenant_id: ctx.scope.tenant_id,
        environment: ctx.scope.environment,
        subject_id: ctx.recipient_id,
        retention_class: :commercial_consent,
        table: "refusals",
        column: "evidence_ct"
      }

      refute ct =~ "Mail/1.0"
      assert {:ok, plain} = Relay.Tenancy.decrypt_field(field, ct)
      refute inspect(plain) =~ "Mail/1.0"
      evidence = Jason.decode!(Relay.Redacted.expose(plain))
      assert %{"source" => "rfc8058", "user_agent" => "Mail/1.0", "ip" => "127.0.0.1"} = evidence
      assert {:ok, _at, 0} = DateTime.from_iso8601(evidence["at"])
    end

    test "PC-35: the request is idempotent and a repeat is neither recorded nor announced again",
         ctx do
      path = path!(ctx)

      for _n <- 1..3, do: assert(response(form_post(path, @one_click), 200) == "")
      assert html_response(form_post(path, "confirm=yes"), 200) =~ "Abonelikten çıktınız."

      assert [_one] = sql!(ctx.scope, @refusals, [ctx.recipient_id])
      assert [_one] = sql!(ctx.scope, @preferences, [ctx.recipient_id])
      assert [_one] = OutboxEvents.data(ctx.scope, "subscription.unsubscribed")
      assert [_one] = OutboxEvents.data(ctx.scope, "preference.changed")
    end

    test "PC-35, INV-18: a recipient who came back is out again by the same link", ctx do
      path = path!(ctx)
      assert response(form_post(path, @one_click), 200) == ""

      assert [["set"]] = sql!(ctx.scope, @back, [Relay.Id.generate(), ctx.recipient_id])
      assert response(form_post(path, @one_click), 200) == ""

      assert [[_key, _channel, "opt_out", "unsubscribe"]] =
               sql!(ctx.scope, @preferences, [ctx.recipient_id])

      assert [_one] = sql!(ctx.scope, @refusals, [ctx.recipient_id])
      assert [_first, _second] = OutboxEvents.data(ctx.scope, "subscription.unsubscribed")
    end

    test "PC-35: a tampered or unknown token is refused and changes nothing", ctx do
      path = path!(ctx)
      [fields, signature] = path |> link_token() |> String.split(".")
      forged = "/abonelik-iptali/" <> fields <> "." <> String.reverse(signature)

      assert response(form_post(forged, @one_click), 404) == ""
      assert html_response(get(build_conn(), forged), 404) =~ "This link is not valid."
      assert response(form_post("/abonelik-iptali/nothing", @one_click), 404) == ""
      assert response(form_post(path, "List-Unsubscribe=Other"), 404) == ""
      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) == []
    end

    test "PC-35: a revoked token is refused and revoking is repeatable", ctx do
      path = path!(ctx)
      token = link_token(path)

      assert :ok = Refusals.revoke_link(token, "sent to the wrong list", "ops@example")
      assert :ok = Refusals.revoke_link(token, "sent to the wrong list", "ops@example")
      assert {:error, :invalid} = Refusals.describe_link(token)
      assert response(form_post(path, @one_click), 404) == ""
      assert html_response(get(build_conn(), path), 404) =~ "This link is not valid."
      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) == []

      other = path!(ctx)
      assert response(form_post(other, @one_click), 200) == ""
    end

    test "PC-35: a mailto request arriving as inbound mail has the result of the one-click request",
         ctx do
      %{mailto: "mailto:unsubscribe@localhost?subject=" <> subject} = links!(ctx, "deals")

      assert {:error, :invalid} = Refusals.mailto("hello", DateTime.utc_now())
      assert :ok = Refusals.mailto(" " <> subject <> " ", DateTime.utc_now())
      assert :ok = Refusals.mailto(subject, DateTime.utc_now())

      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) ==
               [["deals", "email", "opt_out", "unsubscribe"]]

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) ==
               [["mailto", "category", "deals", true]]

      assert [%{"category" => "deals"}] =
               OutboxEvents.data(ctx.scope, "subscription.unsubscribed")
    end
  end

  describe "PC-36 the unsubscribe page" do
    test "PC-36, X-22: the page says unsubscribed and offers the preferences and the brand refusal",
         ctx do
      configure(RelayWeb.Links, preferences_url: "https://shop.example/bildirim-tercihleri")
      path = path!(ctx)
      assert "/abonelik-iptali/" <> _token = path

      page = html_response(form_post(path, "confirm=yes"), 200)
      assert page =~ "Abonelikten çıktınız."
      assert page =~ "Tercihlerimi yönet"
      assert page =~ ~s(href="https://shop.example/bildirim-tercihleri")
      assert page =~ "Bu markadan hiç ticari e-posta almak istemiyorum"
      assert page =~ ~s(name="refuse" value="yes")

      again = html_response(get(build_conn(), path), 200)
      assert again =~ "Abonelikten çıktınız."
      refute again =~ ~s(name="confirm")

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) ==
               [["unsubscribe_link", "category", "news", true]]

      assert sql!(ctx.scope, @consents, [ctx.recipient_id]) == []
    end

    test "PC-36, PC-38, PC-39: the second option is a refusal notice for the brand's marketing e-mail",
         ctx do
      path = path!(ctx)
      assert html_response(form_post(path, "confirm=yes"), 200) =~ "Abonelikten çıktınız."

      refused = html_response(form_post(path, "refuse=yes"), 200)
      assert refused =~ "Bu markadan artık ticari e-posta almayacaksınız."
      refute refused =~ ~s(name="refuse")
      assert html_response(form_post(path, "refuse=yes"), 200) =~ "almayacaksınız"
      assert html_response(get(build_conn(), path), 200) =~ "almayacaksınız"

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == [
               ["unsubscribe_link", "category", "news", true],
               ["unsubscribe_page", "all_marketing", nil, true]
             ]

      assert sql!(ctx.scope, @consents, [ctx.recipient_id]) ==
               [["revoked", "relay", "unsubscribe_page", true]]

      assert [["news", "email", "opt_out", "unsubscribe"]] =
               sql!(ctx.scope, @preferences, [ctx.recipient_id])

      assert sql!(ctx.scope, @suppressions, []) == []
      assert [event] = OutboxEvents.data(ctx.scope, "consent.revoked")
      assert %{"source" => "unsubscribe_page", "scope" => "all_marketing"} = event
      assert event["channel"] == "email"
      assert {:ok, %{state: :refused}} = Refusals.describe_link(link_token(path))
    end

    test "PC-36: the page exists only for commercial and bulk categories", ctx do
      path = path!(ctx, "orders")

      assert html_response(get(build_conn(), path), 404) =~ "This link is not valid."
      assert response(form_post(path, @one_click), 404) == ""
      assert html_response(form_post(path, "refuse=yes"), 404)
      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == []
    end

    test "PC-36: the page is in the recipient's language and English otherwise", ctx do
      {_external_id, recipient_id} = subscriber!(ctx.scope, ctx.token, "de")
      path = path!(%{ctx | recipient_id: recipient_id})

      assert html_response(get(build_conn(), path), 200) =~ "Stop these e-mails?"
      assert html_response(form_post(path, "confirm=yes"), 200) =~ "You are unsubscribed."
      assert html_response(form_post(path, "refuse=yes"), 200) =~ "no commercial e-mail"
    end
  end

  describe "PC-38 PC-39 INV-18 refusal notices" do
    test "PC-38, INV-18: a refusal notice is gate 1c and a preference is a filter; neither becomes the other",
         ctx do
      news = [category: "news", message_class: "marketing", channels: ["email"]]
      deals = [category: "deals", message_class: "marketing", channels: ["email"]]
      F.workflow!(ctx.scope, ctx.token, "newsletter", news)
      F.workflow!(ctx.scope, ctx.token, "offers", deals)
      consent!(ctx)
      refute delivery!(ctx, "newsletter")["rule_id"] in @gates
      refute delivery!(ctx, "offers")["rule_id"] in @gates

      path = path!(ctx)
      assert response(form_post(path, @one_click), 200) == ""
      left = delivery!(ctx, "newsletter")
      assert %{"reason" => "preference_off", "rule_id" => "preference.category_channel"} = left
      refute delivery!(ctx, "offers")["rule_id"] in @gates
      assert [["active", "access", "access", true]] = consents(ctx)

      assert html_response(form_post(path, "refuse=yes"), 200) =~ "almayacaksınız"
      offers = delivery!(ctx, "offers")
      assert %{"reason" => "consent_revoked", "rule_id" => "consent.revoked"} = offers
      assert delivery!(ctx, "newsletter")["rule_id"] == "consent.revoked"

      assert [["news", "email", "opt_out", "unsubscribe"]] =
               sql!(ctx.scope, @preferences, [ctx.recipient_id])
    end

    test "PC-38: closing a category in the preferences is never a refusal notice", ctx do
      out = String.replace(@back, "opt_in", "opt_out")
      assert [["set"]] = sql!(ctx.scope, out, [Relay.Id.generate(), ctx.recipient_id])

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @consents, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @suppressions, []) == []
      assert F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id") == []
      assert OutboxEvents.data(ctx.scope, "consent.revoked") == []
    end

    test "PC-38: a refusal notice reaches the sink from the queue, an exit never", ctx do
      :persistent_term.put(RelayWeb.UnsubscribeTest.Sink, self())
      configure(Relay.Compliance, sink: RelayWeb.UnsubscribeTest.Sink)
      path = path!(ctx)

      assert response(form_post(path, @one_click), 200) == ""
      assert F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id") == []

      assert html_response(form_post(path, "refuse=yes"), 200) =~ "almayacaksınız"
      assert [[refusal_id]] = F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id")
      refute_received {:refused, _scope, _notice}

      args = Map.put(Relay.Scope.to_job_args(ctx.scope), "refusal_id", refusal_id)
      assert :ok = SinkWorker.perform(%Oban.Job{args: args})

      scope = ctx.scope
      assert_received {:refused, ^scope, notice}
      assert %{brand: nil, channel: "email", source: "unsubscribe_page"} = notice
      assert %DateTime{} = notice.occurred_at
      assert Relay.Redacted.expose(notice.address) == "ayse@example.com"
      refute inspect(notice) =~ "ayse@example.com"
      refute inspect(args) =~ "ayse"
    end

    test "PC-39: the scope decides what is written, and the registry's own notice is not sent back",
         ctx do
      base = %{recipient_id: ctx.recipient_id, channel: "email"}

      registry = Map.merge(base, %{source: "iys", ref: "iys:1"})
      assert {:ok, %{result: :applied}} = Relay.Compliance.refuse(ctx.scope, registry)

      assert sql!(ctx.scope, @suppressions, []) == []
      assert F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id") == []

      whole = Map.merge(base, %{source: "complaint", scope: "all_channel", ref: "arf:1"})
      assert {:ok, %{result: :applied, refusal_id: id}} = refuse(ctx, whole)
      assert {:ok, %{result: :exists, refusal_id: ^id}} = refuse(ctx, whole)
      assert sql!(ctx.scope, @suppressions, []) == [["refusal"]]
      assert [[_refusal_id]] = F.jobs(inspect(SinkWorker), ctx.scope, "refusal_id")

      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == [
               ["iys", "all_marketing", nil, true],
               ["complaint", "all_channel", nil, true]
             ]

      assert [["revoked", "relay", "iys", true], ["revoked", "relay", "complaint", true]] =
               sql!(ctx.scope, @consents, [ctx.recipient_id])

      assert sql!(ctx.scope, @preferences, [ctx.recipient_id]) == []
      assert [_iys, _complaint] = OutboxEvents.data(ctx.scope, "consent.revoked")
    end

    test "PC-39, INV-18: a refusal is applied in one transaction and a refused one writes nothing",
         ctx do
      stranger = %{recipient_id: Relay.Id.generate(), channel: "email", ref: "r"}
      unknown = Map.put(stranger, :source, "complaint")
      assert {:error, %Relay.Error{}} = Relay.Compliance.refuse(ctx.scope, unknown)

      missing = %{
        recipient_id: ctx.recipient_id,
        channel: "email",
        source: "rfc8058",
        category: "no_such_category",
        ref: "r2"
      }

      assert {:error, %Relay.Error{code: :not_found}} = refuse(ctx, missing)
      assert sql!(ctx.scope, @refusals, [ctx.recipient_id]) == []
      assert sql!(ctx.scope, @consents, [ctx.recipient_id]) == []
      assert OutboxEvents.data(ctx.scope, "consent.revoked") == []
    end
  end
end
