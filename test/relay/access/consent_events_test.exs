defmodule Relay.Access.ConsentEventsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.ClientStore
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    sub = "pairwise-" <> FakeAccess.random()
    token = F.token(tenant.live)
    F.body(F.request(:post, "/v1/subscribers", token, %{"external_id" => sub}), 201)
    {:ok, recipient_id} = Relay.Subscribers.locate(tenant.live, sub)

    %{
      tenant: tenant,
      scope: tenant.live,
      sub: sub,
      token: token,
      recipient_id: recipient_id,
      access_tenant: tenant.attrs.access_tenant_id
    }
  end

  defp deliver!(type, data, id \\ "evt_" <> FakeAccess.random()) do
    envelope = FakeAccess.event(type, data, id)
    conn = FakeAccess.deliver(envelope)
    assert conn.status == 204
    Api.assert_contract(conn)
    envelope["id"]
  end

  defp receipt_of(webhook_id) do
    FakeAccess.drain!()
    |> Enum.map(&FakeAccess.receipt/1)
    |> Enum.find(&(&1["webhook_id"] == webhook_id))
  end

  defp consent(ctx, attrs) do
    Map.merge(
      %{
        "sub" => ctx.sub,
        "access_tenant_id" => ctx.access_tenant,
        "channel" => "email",
        "status" => "REVOKED",
        "source" => "ACCESS",
        "occurred_at" => "2026-11-01T10:00:00Z",
        "sequence" => 2
      },
      attrs
    )
  end

  defp active(ctx, sequence) do
    consent(ctx, %{
      "status" => "ACTIVE",
      "sequence" => sequence,
      "consent_kind" => "explicit_opt_in",
      "recipient_type" => "individual",
      "text_version_digest" => String.duplicate("ab", 32),
      "evidence" => %{"ip" => "203.0.113.7", "device" => "ios"}
    })
  end

  defp consents(ctx) do
    path = "/v1/subscribers/#{ctx.sub}/consents"
    F.body(F.request(:get, path, ctx.token), 200)["data"]
  end

  defp rows(ctx) do
    {:ok, rows} =
      Relay.Repo.in_scope(ctx.scope, fn _status ->
        Relay.Repo.scoped_query!(
          """
          SELECT status, source, source_sequence, evidence_ct IS NOT NULL, evidence_key_id IS NOT NULL
          FROM relay.consents WHERE recipient_id = $1 ORDER BY source_sequence
          """,
          [ctx.recipient_id]
        ).rows
      end)

    rows
  end

  describe "E-80 PC-59 consent.updated" do
    test "E-80, PC-59: a consent is recorded in lowercase for the subscriber of the pairwise sub",
         ctx do
      id = deliver!("consent.updated", consent(ctx, %{}))

      assert receipt_of(id)["state"] == "processed"
      assert [%{"status" => "revoked", "source" => "access"} = shown] = consents(ctx)
      assert shown["channel"] == "email"
      assert rows(ctx) == [["revoked", "access", 2, false, false]]
    end

    test "E-80, E-36: a repeated delivery or sequence and an older sequence change nothing",
         ctx do
      first = deliver!("consent.updated", consent(ctx, %{}))
      assert receipt_of(first)["state"] == "processed"

      FakeAccess.deliver(FakeAccess.event("consent.updated", consent(ctx, %{}), first))
      same = deliver!("consent.updated", consent(ctx, %{"status" => "PENDING"}))
      older = deliver!("consent.updated", active(ctx, 1))

      assert receipt_of(same)["state"] == "processed"
      assert receipt_of(older)["state"] == "processed"
      assert rows(ctx) == [["revoked", "access", 2, false, false]]
      assert [%{"status" => "revoked"}] = consents(ctx)
    end

    test "PC-59: an active consent keeps its evidence encrypted under the subject's consent key",
         ctx do
      id = deliver!("consent.updated", active(ctx, 3))

      assert receipt_of(id)["state"] == "processed"
      assert [%{"status" => "active", "consent_kind" => "explicit_opt_in"}] = consents(ctx)
      assert rows(ctx) == [["active", "access", 3, true, true]]

      revoked = deliver!("consent.updated", consent(ctx, %{"sequence" => 4}))
      assert receipt_of(revoked)["state"] == "processed"
      assert [%{"status" => "revoked"}] = consents(ctx)
      assert length(rows(ctx)) == 2
    end

    test "PC-59: an active consent without evidence and an unreadable consent are rejected",
         ctx do
      bare = consent(ctx, %{"status" => "ACTIVE", "sequence" => 5})
      id = deliver!("consent.updated", bare)
      assert %{"state" => "rejected", "reason" => "evidence_required"} = receipt_of(id)

      odd = deliver!("consent.updated", consent(ctx, %{"status" => "MAYBE"}))
      assert %{"state" => "rejected", "reason" => "invalid_consent"} = receipt_of(odd)
      assert rows(ctx) == []
    end

    test "E-80: a sub without a subscriber creates nothing", ctx do
      stranger = "pairwise-" <> FakeAccess.random()
      id = deliver!("consent.updated", consent(ctx, %{"sub" => stranger}))

      assert receipt_of(id)["state"] == "processed"
      assert Relay.Subscribers.locate(ctx.scope, stranger) == {:ok, nil}
      assert rows(ctx) == []
    end

    test "E-80, PC-59: the brand is the sub-tenant of the organization once it is mapped", ctx do
      organization = "org_" <> FakeAccess.random()
      branded = consent(ctx, %{"access_organization_id" => organization})
      waiting = deliver!("consent.updated", branded)

      assert %{"state" => "deferred", "reason" => "subtenant_not_found"} = receipt_of(waiting)

      mapped =
        deliver!("organization.created", %{
          "access_tenant_id" => ctx.access_tenant,
          "access_organization_id" => organization,
          "name" => "Shop"
        })

      assert receipt_of(mapped)["state"] == "processed"
      assert receipt_of(waiting)["state"] == "processed"

      {:ok, subtenant} =
        ClientStore.in_scope(ctx.scope, fn _status -> ClientStore.subtenant(organization) end)

      assert [%{"brand" => brand}] = consents(ctx)
      assert brand == Relay.ExternalId.encode("stn", subtenant.id)
    end
  end
end
