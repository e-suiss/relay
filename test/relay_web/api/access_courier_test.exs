defmodule RelayWeb.Api.AccessCourierTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Api.Courier.Catalog
  alias Relay.Api.PayloadErasure
  alias Relay.Api.Courier.Provision
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @environment "00000000-0000-4000-8000-00000000000a"
  @phone "+905321112233"
  @email "Ayse@Example.com"

  setup do
    :ok = FakeAccess.install!()
    access = TenantFixture.tenant!(platform_product: "access")
    customer = TenantFixture.tenant!()

    %{
      scope: access.live,
      token: F.token(access.live),
      customer: customer,
      access_tenant: customer.attrs.access_tenant_id
    }
  end

  defp message(ctx, name, data, overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => Ecto.UUID.generate(),
        "source" => "urn:suiss:access:environment:" <> @environment,
        "type" => "relay.message.#{name}.v1",
        "subject" => "usr_" <> TenantFixture.random(),
        "time" => DateTime.to_iso8601(DateTime.utc_now()),
        "datacontenttype" => "application/json",
        "accesstenant" => ctx.access_tenant,
        "accessenvironment" => @environment,
        "data" => data
      },
      overrides
    )
  end

  defp post(ctx, event) do
    auth = RelayTest.Api.auth(ctx.token, :post, "/v1/events")

    headers =
      [{"content-type", "application/cloudevents+json"}, {"idempotency-key", event["id"]}] ++
        auth

    :post
    |> RelayTest.Api.conn("/v1/events", Jason.encode!(event), headers)
    |> RelayTest.Api.call(RelayWeb.Router)
  end

  defp problem(conn, status) do
    body = F.body(conn, status)
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    body
  end

  defp later(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()

  defp notification(ctx, body) do
    [%{"notification_id" => id}] = body["notifications"]
    {:ok, uuid} = Relay.ExternalId.decode(id, ["ntf"])

    {:ok, [row]} =
      Repo.in_scope(ctx.scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT n.message_class::text, n.security_subtype, n.expires_at, r.transient
          FROM relay.notifications n
          JOIN relay.recipients r ON r.tenant_id = n.tenant_id
            AND r.environment = n.environment AND r.id = n.recipient_id
          WHERE n.id = $1
          """,
          [uuid]
        ).rows
      end)

    [class, subtype, expires_at, transient] = row
    deliveries = F.body(F.request(:get, "/v1/notifications/#{id}/deliveries", ctx.token), 200)

    %{
      class: class,
      subtype: subtype,
      expires_at: expires_at,
      transient: transient,
      channels: Enum.map(deliveries["data"], & &1["channel"])
    }
  end

  defp subscribers(ctx),
    do: F.body(F.request(:get, "/v1/subscribers", ctx.token), 200)["data"]

  defp erasure_args(ctx, body) do
    {:ok, event_id} = Relay.ExternalId.decode(body["id"], ["evt"])
    [[reason]] = F.jobs("Relay.Api.PayloadErasure", ctx.scope, "reason")
    [[queued]] = F.jobs("Relay.Api.PayloadErasure", ctx.scope, "event_id")
    assert queued == Relay.Id.to_string(event_id)

    {event_id,
     Map.merge(Relay.Scope.to_job_args(ctx.scope), %{"event_id" => queued, "reason" => reason})}
  end

  defp payload(ctx, event_id) do
    {:ok, [row]} =
      Repo.in_scope(ctx.scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT p.data_ct IS NOT NULL, p.erase_reason
          FROM relay.events e
          JOIN relay.event_payloads p ON p.tenant_id = e.tenant_id
            AND p.environment = e.environment AND p.event_id = e.id
            AND p.created_at = e.payload_created_at
          WHERE e.id = $1
          """,
          [event_id]
        ).rows
      end)

    row
  end

  describe "E-108 Access's messages" do
    test "E-108 INV-22: an OTP by SMS reaches an inline number as a transient recipient with the otp_oob subtype",
         ctx do
      data = %{
        "recipient" => %{"phone" => @phone},
        "locale" => "tr-TR",
        "code" => "482913",
        "purpose" => "sign_in",
        "expires_at" => later(300)
      }

      body = F.body(post(ctx, message(ctx, "sms_otp", data)), 202)
      seen = notification(ctx, body)

      assert seen.class == "security"
      assert seen.subtype == "otp_oob"
      assert seen.transient == true
      assert seen.channels == ["sms"]
      assert %DateTime{} = seen.expires_at
      assert subscribers(ctx) == []
    end

    test "E-108 INV-22: an OTP by e-mail names the email_verification subtype and the e-mail channel only",
         ctx do
      data = %{
        "recipient" => %{"email" => @email},
        "code" => "120934",
        "purpose" => "verify_address",
        "expires_at" => later(600)
      }

      body = F.body(post(ctx, message(ctx, "otp", data)), 202)
      seen = notification(ctx, body)

      assert seen.subtype == "email_verification"
      assert seen.channels == ["email"]
      assert seen.transient == true
    end

    test "INV-22 E-108: the code of an Access OTP leaves the stored event once its delivery ends",
         ctx do
      data = %{
        "recipient" => %{"phone" => @phone},
        "code" => "482913",
        "purpose" => "sign_in",
        "expires_at" => later(300)
      }

      body = F.body(post(ctx, message(ctx, "sms_otp", data)), 202)
      {event_id, args} = erasure_args(ctx, body)

      assert args["reason"] == "security_subtype"
      assert payload(ctx, event_id) == [true, nil]

      F.body(F.request(:post, "/v1/events/#{body["id"]}/cancel", ctx.token, %{}), 200)

      assert PayloadErasure.perform(%Oban.Job{args: args}) == :ok
      assert payload(ctx, event_id) == [false, "security_subtype"]
      assert PayloadErasure.perform(%Oban.Job{args: args}) == :ok
    end

    test "INV-22 E-108: an approval link is sent with retention none and erased the same way",
         ctx do
      data = %{
        "recipient" => %{"email" => @email},
        "link" => "https://access.test/login?reason=ciba&request=def",
        "client" => "Banka",
        "expires_at" => later(120)
      }

      body = F.body(post(ctx, message(ctx, "ciba_invite", data)), 202)
      {_event_id, args} = erasure_args(ctx, body)

      assert args["reason"] == "retention_none"

      {:deliver, invite} = Catalog.lookup("relay.message.ciba_invite.v1")
      {:deliver, notice} = Catalog.lookup("relay.message.password_changed.v1")
      assert Catalog.erasure(invite) == {"retention_none", true}
      assert Catalog.erasure(notice) == nil
    end

    test "E-108 E-12: the same address is one transient recipient, never a subscriber profile",
         ctx do
      data = %{"recipient" => %{"email" => @email}, "at" => later(-60), "method" => "passkey"}

      first = F.body(post(ctx, message(ctx, "new_sign_in", data)), 202)
      again = F.body(post(ctx, message(ctx, "password_changed", Map.delete(data, "method"))), 202)

      assert [%{"recipient_id" => recipient}] = first["notifications"]
      assert [%{"recipient_id" => ^recipient}] = again["notifications"]
      assert notification(ctx, first).class == "security"
      assert subscribers(ctx) == []
    end

    test "E-108 E-10: a CIBA invitation is action_required, expires with the request and carries its link only into the message",
         ctx do
      expires_at = later(120)

      data = %{
        "recipient" => %{"email" => @email},
        "link" => "https://access.test/login?reason=ciba&request=abc",
        "client" => "Banka <Mobil>",
        "binding_message" => "K7-42",
        "expires_at" => expires_at
      }

      body = F.body(post(ctx, message(ctx, "ciba_invite", data)), 202)
      seen = notification(ctx, body)

      assert seen.class == "action_required"
      assert seen.subtype == nil
      assert seen.channels == ["email"]
      {:ok, expected, _offset} = DateTime.from_iso8601(expires_at)
      assert DateTime.diff(seen.expires_at, expected) == 0
    end

    test "E-108: a push approval to an approver device Relay cannot route is a permanent 422",
         ctx do
      data = %{
        "recipient" => %{"device" => String.duplicate("A", 43)},
        "challenge" => "c2lnbmF0dXJlLWNoYWxsZW5nZQ",
        "application" => "Portal",
        "action" => "sign in",
        "expires_at" => later(120)
      }

      body = problem(post(ctx, message(ctx, "push_approval", data)), 422)
      assert body["code"] == "recipient_not_found"
    end

    test "E-108: an event outside Access's message schema is a permanent 422", ctx do
      data = %{"recipient" => %{"phone" => @phone}, "at" => later(-60)}
      event = message(ctx, "new_sign_in", data)

      assert problem(post(ctx, event), 422)["code"] == "validation_failed"

      other = Map.put(event, "source", "urn:suiss:access:environment:" <> Ecto.UUID.generate())
      other = Map.update!(other, "data", &Map.put(&1, "method", "otp"))
      assert problem(post(ctx, other), 422)["code"] == "validation_failed"
    end

    test "E-108: an environment the tenant does not have is a permanent 422, an unknown tenant a transient 503",
         ctx do
      data = %{"recipient" => %{"phone" => @phone}, "at" => later(-60), "method" => "otp"}
      environment = "00000000-0000-4000-8000-0000000000ff"

      foreign =
        message(ctx, "new_sign_in", data, %{
          "source" => "urn:suiss:access:environment:" <> environment,
          "accessenvironment" => environment
        })

      assert problem(post(ctx, foreign), 422)["code"] == "validation_failed"

      unknown = message(ctx, "new_sign_in", data, %{"accesstenant" => "acc_unmapped"})
      conn = post(ctx, unknown)
      assert problem(conn, 503)["code"] == "service_unavailable"
      assert get_resp_header(conn, "retry-after") != []
    end

    test "E-108: a message sent again with the same id answers the first acceptance", ctx do
      data = %{"recipient" => %{"phone" => @phone}, "at" => later(-60), "method" => "otp"}
      event = message(ctx, "new_sign_in", data)

      first = post(ctx, event)
      again = post(ctx, event)
      assert first.status == 202
      assert again.resp_body == first.resp_body
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
    end

    test "E-108: an Access message from another tenant goes through that tenant's own mapping",
         ctx do
      token = F.token(ctx.customer.live)
      data = %{"recipient" => %{"phone" => @phone}, "at" => later(-60), "method" => "otp"}
      event = message(ctx, "new_sign_in", data)

      conn = post(%{ctx | token: token}, event)
      assert problem(conn, 422)["code"] == "event_type_not_mapped"
    end
  end

  describe "E-108 the protected catalogue" do
    test "E-108: every type of the vendored schema has an entry, and its texts use only its own fields" do
      for type <- Catalog.types() do
        case Catalog.lookup(type) do
          :iys ->
            assert type == "relay.message.iys_consent.v1"

          {:deliver, entry} ->
            fields = MapSet.new(Catalog.data_fields(type))
            template = Catalog.template(entry)

            for channel <- ~w(email sms push), locale <- ~w(tr en) do
              cell = get_in(template, ["cells", channel, locale])
              assert is_map(cell), "#{type} #{channel} #{locale}"

              for text <- Map.values(cell),
                  [_, name] <- Regex.scan(~r/\{\{\s*([a-z_]+)/, text) do
                assert MapSet.member?(fields, name), "#{type} uses #{name}"
              end
            end

            assert entry.class in ["security", "action_required"]
            refute Map.has_key?(Catalog.event_schema(type)["properties"], "recipient")
        end
      end

      assert length(Catalog.names()) + 1 == length(Catalog.types())
    end

    test "E-108 E-35: every delivered type gets its protected workflow and producer template",
         ctx do
      for type <- Catalog.types(), {:deliver, entry} <- [Catalog.lookup(type)] do
        assert Provision.ensure(ctx.scope, entry) == :ok, type

        assert {:ok, {:ok, workflow}} = Relay.Workflow.resolve_published(ctx.scope, entry.key)
        assert workflow["message_class"] == entry.class

        {:ok, template} =
          Repo.in_scope(ctx.scope, fn _status -> Relay.TemplateStore.template(entry.key, nil) end)

        assert template["owner_product"] == "access"
        assert is_binary(template["live_version_id"])
      end

      assert Provision.ensure(ctx.scope, elem(Catalog.lookup("relay.message.otp.v1"), 1)) == :ok
    end
  end
end
