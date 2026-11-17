defmodule RelayWeb.Api.PayloadErasureTest do
  use Relay.DataCase, async: false

  alias Relay.Api.PayloadErasure
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @worker "Relay.Api.PayloadErasure"

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp event(overrides) do
    Map.merge(
      %{
        "workflow" => "order-shipped",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"}
      },
      overrides
    )
  end

  defp accepted(token, body), do: F.body(F.request(:post, "/v1/events", token, body), 202)

  defp event_id(body) do
    {:ok, id} = Relay.ExternalId.decode(body["id"], ["evt"])
    id
  end

  defp queued(scope) do
    Enum.zip_with(
      F.jobs(@worker, scope, "event_id"),
      F.jobs(@worker, scope, "reason"),
      fn [id], [reason] -> {id, reason} end
    )
  end

  defp args(scope, id, reason) do
    Map.merge(Relay.Scope.to_job_args(scope), %{
      "event_id" => Relay.Id.to_string(id),
      "reason" => reason
    })
  end

  defp payload(scope, id) do
    {:ok, [row]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT p.data_ct IS NOT NULL, p.erase_reason
          FROM relay.events e
          JOIN relay.event_payloads p ON p.tenant_id = e.tenant_id
            AND p.environment = e.environment AND p.event_id = e.id
            AND p.created_at = e.payload_created_at
          WHERE e.id = $1
          """,
          [id]
        ).rows
      end)

    row
  end

  defp cancel(token, body),
    do: F.body(F.request(:post, "/v1/events/#{body["id"]}/cancel", token, %{}), 200)

  describe "INV-22 INV-26 erasure of every secret-carrying event" do
    test "INV-26 API-26: a tenant's retention none event queues its erasure at acceptance",
         ctx do
      body = accepted(ctx.token, event(%{"retention" => "none"}))
      id = event_id(body)

      assert queued(ctx.scope) == [{Relay.Id.to_string(id), "retention_none"}]
      assert payload(ctx.scope, id) == [true, nil]

      cancel(ctx.token, body)

      assert PayloadErasure.perform(%Oban.Job{args: args(ctx.scope, id, "retention_none")}) ==
               :ok

      assert payload(ctx.scope, id) == [false, "retention_none"]
    end

    test "INV-22: a tenant's own OTP event queues its erasure with the security_subtype reason",
         ctx do
      :ok = F.category!(ctx.token, "login", "security")
      cells = %{"sms" => %{"body" => "Kodunuz {{ order }}"}}
      definition = F.template_definition(cells)
      :ok = F.template!(ctx.scope, "order-shipped", "login", definition: definition)
      opts = [category: "login", message_class: "security", channels: ["sms"]]
      F.workflow!(ctx.scope, ctx.token, "login-code", opts)

      expires = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 600))
      to = %{"id" => "user-" <> TenantFixture.random(), "phone" => "+905551112233"}

      body =
        accepted(ctx.token, %{
          "workflow" => "login-code",
          "to" => [to],
          "data" => %{"order" => "482913"},
          "security_subtype" => "otp_oob",
          "expires_at" => expires
        })

      id = event_id(body)
      assert queued(ctx.scope) == [{Relay.Id.to_string(id), "security_subtype"}]

      cancel(ctx.token, body)

      assert PayloadErasure.perform(%Oban.Job{args: args(ctx.scope, id, "security_subtype")}) ==
               :ok

      assert payload(ctx.scope, id) == [false, "security_subtype"]
    end

    test "INV-26: a retention none row of a batch queues its own erasure", ctx do
      rows = [event(%{"retention" => "none"}), event(%{})]
      conn = F.request(:post, "/v1/events/batch", ctx.token, %{"events" => rows})
      body = F.body(conn, 202)

      [kept, _plain] = body["results"]
      id = event_id(kept["event"])
      assert queued(ctx.scope) == [{Relay.Id.to_string(id), "retention_none"}]
    end

    test "INV-22: an event without a secret queues no erasure", ctx do
      accepted(ctx.token, event(%{}))
      assert queued(ctx.scope) == []
    end

    test "INV-26 WF-59 (5): the data stays while a run still waits for a later step", ctx do
      mail = %{
        "type" => "channel",
        "key" => "later",
        "channel" => "email",
        "template" => "order-shipped"
      }

      steps = [%{"type" => "delay", "key" => "wait", "duration" => "PT1H"}, mail]
      definition = Map.put(F.definition(), "steps", steps)
      body = %{"key" => "delayed", "definition" => definition}
      created = F.request(:post, "/v1/workflows", ctx.token, body)
      assert created.status == 201, created.resp_body
      F.publish!(ctx.scope, ctx.token, "delayed")

      accepted = accepted(ctx.token, event(%{"workflow" => "delayed", "retention" => "none"}))
      id = event_id(accepted)
      job = %Oban.Job{args: args(ctx.scope, id, "retention_none")}

      assert PayloadErasure.perform(job) == {:snooze, 30}
      assert payload(ctx.scope, id) == [true, nil]

      cancel(ctx.token, accepted)

      assert PayloadErasure.perform(job) == :ok
      assert payload(ctx.scope, id) == [false, "retention_none"]
    end
  end
end
