defmodule RelayWeb.Api.MailboxApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Relay.Inbox.Mailbox, as: Core
  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    client = Relay.ExternalId.encode("cli", Relay.Id.generate())

    %{
      scope: scope,
      client: client,
      token: Api.token(scope, ["agents"], api_client_id: client)
    }
  end

  defp other(scope, scopes) do
    client = Relay.ExternalId.encode("cli", Relay.Id.generate())
    Api.token(scope, scopes, api_client_id: client)
  end

  defp mailbox(ctx), do: F.body(F.request(:get, "/v1/mailbox", ctx.token), 200)

  defp append!(ctx, mailbox) do
    {:ok, mailbox_id} = Relay.ExternalId.decode(mailbox["id"], ["mbx"])
    id = Relay.Id.generate()

    record = %{
      id: id,
      mailbox_id: mailbox_id,
      kind: :message,
      event_type: "agent.note",
      payload_digest: :crypto.strong_rand_bytes(32)
    }

    {:ok, {:appended, _epoch, _seq}} = Core.append(ctx.scope, record)
    Relay.ExternalId.encode("mbr", id)
  end

  defp lease(token, max, headers \\ []),
    do: F.request(:post, "/v1/mailbox/leases", token, %{"max" => max}, headers)

  defp ack(token, lease_id, ids) do
    body = %{"lease_id" => lease_id, "record_ids" => ids}
    F.body(F.request(:post, "/v1/mailbox/acks", token, body), 200)
  end

  defp ids(records), do: Enum.map(records, & &1["id"])

  defp advance!(scope, seconds) do
    advanced =
      VirtualClock.advance(scope, seconds * 1000, TenantFixture.digest(), TenantFixture.actor())

    assert {:ok, {:advanced, _offset, _now}} = advanced
  end

  describe "AG-20 AG-64 the mailbox of the caller" do
    test "AG-64: an API client's mailbox opens lazily, once, with the settings in force", ctx do
      view = mailbox(ctx)

      assert %{
               "object" => "mailbox",
               "state" => "active",
               "lease_duration" => "PT60S",
               "max_redeliveries" => 5
             } = view

      assert view["owner"] == ctx.client
      assert view["cursor"] == view["acked_cursor"]
      assert mailbox(ctx)["id"] == view["id"]

      stranger = F.body(F.request(:get, "/v1/mailbox", other(ctx.scope, ["agents"])), 200)
      refute stranger["id"] == view["id"]
    end

    test "AG-64: an agent credential without an agent record gets no API client mailbox", ctx do
      token = Api.token(ctx.scope, ["agents"], api_client_id: ctx.client, agent: true)

      for {method, path, body} <- [
            {:get, "/v1/mailbox", nil},
            {:post, "/v1/mailbox/leases", %{}},
            {:get, "/v1/mailbox/records", nil}
          ] do
        problem = F.body(F.request(method, path, token, body), 404)
        assert problem["code"] == "agent_not_found"
      end
    end

    test "AG-20: the mailbox operations need the agents scope", ctx do
      reader = other(ctx.scope, ["read"])

      assert F.request(:get, "/v1/mailbox", reader).status == 403
      assert F.request(:post, "/v1/mailbox/leases", reader, %{}).status == 403
      assert F.request(:get, "/v1/mailbox/records", reader).status == 403
    end

    test "AG-20, AG-24: records are leased in order, acknowledged by their lease and read after the acknowledged position",
         ctx do
      box = mailbox(ctx)
      [a, b, c] = for _ <- 1..3, do: append!(ctx, box)
      key = F.key()

      first = F.body(lease(ctx.token, 2, [key]), 200)
      assert %{"object" => "mailbox_lease", "lease_id" => lease_id} = first
      assert ids(first["records"]) == [a, b]
      assert Enum.map(first["records"], & &1["state"]) == ["leased", "leased"]
      assert Enum.map(first["records"], & &1["delivery_count"]) == [1, 1]

      again = lease(ctx.token, 2, [key])
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
      assert F.body(again, 200) == first

      second = F.body(lease(ctx.token, 10), 200)
      assert ids(second["records"]) == [c]

      stolen = ack(ctx.token, second["lease_id"], [a])
      assert stolen["results"] == [%{"record_id" => a, "result" => "lease_lost"}]

      unknown = Relay.ExternalId.encode("mbr", Relay.Id.generate())
      acked = ack(ctx.token, lease_id, [a, unknown])

      assert acked["results"] == [
               %{"record_id" => a, "result" => "acked"},
               %{"record_id" => unknown, "result" => "not_found"}
             ]

      missed = F.body(F.request(:get, "/v1/mailbox/records", ctx.token), 200)
      assert %{"object" => "mailbox_records", "has_more" => false} = missed
      assert missed["resync_required"] == false
      assert ids(missed["records"]) == [b, c]
      assert mailbox(ctx)["acked_cursor"] == acked["acked_cursor"]

      page = F.body(F.request(:get, "/v1/mailbox/records?limit=1", ctx.token), 200)
      assert ids(page["records"]) == [b]
      assert page["has_more"]

      rest =
        F.body(
          F.request(:get, "/v1/mailbox/records?since=#{page["cursor"]}", ctx.token),
          200
        )

      assert ids(rest["records"]) == [c]
      assert rest["cursor"] == mailbox(ctx)["cursor"]

      invalid = F.request(:get, "/v1/mailbox/records?since=nowhere", ctx.token)
      assert [%{"pointer" => "/since"}] = F.body(invalid, 422)["errors"]
    end
  end

  describe "AG-21 durable handle" do
    test "AG-21: a record is read by its handle by its owner and with the read scope", ctx do
      record = append!(ctx, mailbox(ctx))
      path = "/v1/mailbox/records/" <> record

      view = F.body(F.request(:get, path, ctx.token), 200)
      assert %{"object" => "mailbox_record", "state" => "available", "delivery_count" => 0} = view
      assert view["id"] == record
      assert view["payload_digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/

      assert F.body(F.request(:get, path, other(ctx.scope, ["read"])), 200) == view

      stranger = F.body(F.request(:get, path, other(ctx.scope, ["agents"])), 404)
      assert stranger["code"] == "mailbox_record_not_found"

      missing = F.request(:get, "/v1/mailbox/records/mbr_nothing", ctx.token)
      assert F.body(missing, 404)["code"] == "mailbox_record_not_found"
    end
  end

  describe "AG-22 AG-53 limits and dead letters" do
    test "AG-53: a lease request above the limit is refused with the limit in the error body",
         ctx do
      problem = F.body(lease(ctx.token, 101), 422)

      assert %{"code" => "validation_failed", "limit" => 100, "actual" => 101} = problem
      assert problem["limit_name"] == "mailbox.lease_max_records"
      assert [%{"pointer" => "/max", "code" => "too_long"}] = problem["errors"]

      assert F.request(:post, "/v1/mailbox/leases", ctx.token, %{"max" => 0}).status == 422
      assert F.body(lease(ctx.token, 100), 200)["records"] == []
    end

    test "AG-20, AG-22: an unacknowledged record is delivered again, then dead-lettered, kept and listed",
         ctx do
      change = %{
        key: "mailbox.lease",
        value: %{"lease_seconds" => 10, "max_redeliveries" => 1},
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      assert {:ok, _} = Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())
      box = mailbox(ctx)
      assert %{"lease_duration" => "PT10S", "max_redeliveries" => 1} = box
      record = append!(ctx, box)

      first = F.body(lease(ctx.token, 1), 200)
      assert [%{"delivery_count" => 1}] = first["records"]
      assert F.body(lease(ctx.token, 1), 200)["records"] == []

      advance!(ctx.scope, 11)
      second = F.body(lease(ctx.token, 1), 200)
      assert [%{"id" => ^record, "delivery_count" => 2}] = second["records"]

      late = ack(ctx.token, first["lease_id"], [record])
      assert late["results"] == [%{"record_id" => record, "result" => "lease_lost"}]

      advance!(ctx.scope, 11)
      assert F.body(lease(ctx.token, 1), 200)["records"] == []

      dead = F.body(F.request(:get, "/v1/mailbox/dead_letters", ctx.token), 200)
      assert %{"object" => "list", "has_more" => false} = dead
      assert [%{"id" => ^record, "state" => "dead_lettered"} = listed] = dead["data"]
      assert listed["delivery_count"] == 2

      view = F.body(F.request(:get, "/v1/mailbox/records/" <> record, ctx.token), 200)
      assert view["state"] == "dead_lettered"
      assert is_binary(view["dead_lettered_at"])

      refused = ack(ctx.token, second["lease_id"], [record])
      assert refused["results"] == [%{"record_id" => record, "result" => "lease_lost"}]

      assert {:ok, [[1]]} =
               Repo.in_scope(ctx.scope, fn _status ->
                 Repo.scoped_query!("SELECT count(*) FROM relay.mailbox_records", []).rows
               end)

      reader = other(ctx.scope, ["read"])
      owned = "/v1/mailbox/dead_letters?mailbox_id=" <> box["id"]
      assert F.body(F.request(:get, owned, reader), 200)["data"] == dead["data"]
      assert F.body(F.request(:get, owned, ctx.token), 200)["data"] == dead["data"]
      assert F.body(F.request(:get, "/v1/mailbox/dead_letters", reader), 200)["data"] == []
      assert F.request(:get, owned, other(ctx.scope, ["agents"])).status == 403

      unknown = Relay.ExternalId.encode("mbx", Relay.Id.generate())
      gone = F.request(:get, "/v1/mailbox/dead_letters?mailbox_id=" <> unknown, reader)
      assert F.body(gone, 404)["code"] == "mailbox_not_found"
    end
  end

  describe "AG-23 a suspended mailbox" do
    test "AG-23: a suspended mailbox hands out no lease and is still read", ctx do
      box = mailbox(ctx)
      record = append!(ctx, box)
      {:ok, mailbox_id} = Relay.ExternalId.decode(box["id"], ["mbx"])

      {:ok, _changed} =
        Repo.in_scope(ctx.scope, fn _status ->
          Repo.call!("relay_fn.mailbox_set_state", [mailbox_id, "suspended", nil])
        end)

      problem = F.body(lease(ctx.token, 1), 409)
      assert problem["code"] == "mailbox_inactive"
      assert mailbox(ctx)["state"] == "suspended"

      read = F.body(F.request(:get, "/v1/mailbox/records", ctx.token), 200)
      assert ids(read["records"]) == [record]
    end
  end
end
