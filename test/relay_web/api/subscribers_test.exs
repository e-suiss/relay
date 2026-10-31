defmodule RelayWeb.Api.SubscribersTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp external_id, do: "user-" <> TenantFixture.random()

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp create(token, body), do: F.request(:post, "/v1/subscribers", token, body)

  describe "API-66 subscriber resources" do
    test "API-66: create answers 201 with masked fields and a second create is 409", ctx do
      id = external_id()
      body = F.body(create(ctx.token, %{"external_id" => id, "email" => "Ayse@Example.com"}), 201)

      assert body["object"] == "subscriber"
      assert body["external_id"] == id
      assert body["email"] == "a***@example.com"
      assert body["channels"]["email"] == %{"reachable" => true, "reason" => nil}
      assert body["channels"]["sms"] == %{"reachable" => false, "reason" => "no_address"}
      assert body["channels"]["in_app"]["reachable"] == true

      assert code(create(ctx.token, %{"external_id" => id}), 409) == "resource_conflict"
    end

    test "API-66: PUT creates with 201 the first time and replaces with 200 after", ctx do
      id = external_id()
      path = "/v1/subscribers/" <> id
      first = F.request(:put, path, ctx.token, %{"email" => "a@example.com", "locale" => "tr-TR"})
      assert F.body(first, 201)["locale"] == "tr-TR"

      second = F.body(F.request(:put, path, ctx.token, %{"name" => "Ayşe"}), 200)
      assert second["locale"] == nil
      assert second["email"] == nil
      assert second["name"] == "A***"
      assert second["version"] == 2
    end

    test "S-66: PATCH needs If-Match; a stale version is 412 and a fresh one merges", ctx do
      id = external_id()
      created = create(ctx.token, %{"external_id" => id, "email" => "a@example.com"})
      [etag] = get_resp_header(created, "etag")
      path = "/v1/subscribers/" <> id

      patch = fn headers ->
        RelayTest.Api.conn(:patch, path, Jason.encode!(%{"locale" => "en-GB"}), [
          {"content-type", "application/merge-patch+json"},
          {"authorization", "Bearer " <> ctx.token},
          F.key() | headers
        ])
        |> RelayTest.Api.call(RelayWeb.Router)
      end

      assert code(patch.([]), 428) == "precondition_required"
      assert code(patch.([{"if-match", ~s("99")}]), 412) == "precondition_failed"

      merged = F.body(patch.([{"if-match", etag}]), 200)
      assert merged["locale"] == "en-GB"
      assert merged["email"] == "a***@example.com"
    end

    test "API-66: an unknown subscriber is 404 subscriber_not_found", ctx do
      assert code(F.request(:get, "/v1/subscribers/" <> external_id(), ctx.token), 404) ==
               "subscriber_not_found"
    end

    test "API-56: subscribers list with cursors", ctx do
      for _ <- 1..3, do: F.body(create(ctx.token, %{"external_id" => external_id()}), 201)

      page = F.body(F.request(:get, "/v1/subscribers?limit=2", ctx.token), 200)
      assert length(page["data"]) == 2
      assert page["has_more"]
      assert is_binary(page["next_cursor"])
    end

    test "API-66: bulk upsert answers 207 with per-row results", ctx do
      rows = [
        %{"ref" => "a", "external_id" => external_id(), "email" => "x@example.com"},
        %{"ref" => "b", "external_id" => external_id(), "locale" => "not a locale"}
      ]

      conn = F.request(:post, "/v1/subscribers/bulk", ctx.token, %{"subscribers" => rows})
      assert conn.status == 422
      assert F.body(conn, 422)["code"] == "validation_failed"

      rows = [
        %{"ref" => "a", "external_id" => external_id(), "email" => "x@example.com"},
        %{"ref" => "b", "external_id" => external_id()}
      ]

      body =
        F.body(F.request(:post, "/v1/subscribers/bulk", ctx.token, %{"subscribers" => rows}), 200)

      assert Enum.map(body["results"], & &1["status"]) == ["created", "created"]
      assert body["summary"] == %{"total" => 2, "accepted" => 2, "rejected" => 0}
    end

    test "API-66: DELETE answers 202 and its job erases the subject by crypto-shredding", ctx do
      :ok = TenantFixture.retention_periods!()
      id = external_id()
      F.body(create(ctx.token, %{"external_id" => id, "email" => "e@example.com"}), 201)

      body = F.body(F.request(:delete, "/v1/subscribers/" <> id, ctx.token), 202)
      assert body["object"] == "subscriber_deletion"
      assert body["status"] == "pending"
      assert "sdr_" <> _ = body["id"]

      shown = F.body(F.request(:get, "/v1/subscribers/" <> id, ctx.token), 200)
      assert shown["state"] == "deletion_requested"

      for [request] <- F.jobs("Relay.Subscribers.Erasure", ctx.scope, "request_id") do
        [[recipient]] = F.jobs("Relay.Subscribers.Erasure", ctx.scope, "recipient_id")
        {:ok, request_id} = Relay.Id.parse(request)
        {:ok, recipient_id} = Relay.Id.parse(recipient)
        assert {:ok, :completed} = Relay.Subscribers.erase(ctx.scope, request_id, recipient_id)
      end

      assert code(F.request(:get, "/v1/subscribers/" <> id, ctx.token), 404) ==
               "subscriber_not_found"

      {:ok, rows} =
        Relay.Repo.in_scope(ctx.scope, fn _status ->
          Relay.Repo.scoped_query!(
            "SELECT state FROM relay.recipient_addresses WHERE kind = 'email'",
            []
          ).rows
        end)

      assert rows == [["deleted"]]
    end
  end
end
