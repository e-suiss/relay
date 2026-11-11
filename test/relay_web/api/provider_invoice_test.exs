defmodule RelayWeb.Api.ProviderInvoiceTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup_all do
    day = Date.add(DateTime.to_date(Relay.Clock.utc_now()), -1)
    from = DateTime.new!(Date.beginning_of_month(day), ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(Date.end_of_month(day), 1), ~T[00:00:00], "Etc/UTC")
    conn = Relay.SqlCase.connect(:admin)

    %{rows: [[result]]} =
      Postgrex.query!(conn, "SELECT relay_private.partition_create($1, $2, $3)", [
        "usage_records",
        from,
        to
      ])

    GenServer.stop(conn)
    assert result in ["created", "exists"]
    :ok
  end

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, other: tenant.test, token: F.token(tenant.live)}
  end

  defp yesterday, do: Date.add(DateTime.to_date(Relay.Clock.utc_now()), -1)

  defp usage!(scope, attrs) do
    usage =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          usage_day: yesterday(),
          channel: :sms,
          provider: "netgsm",
          destination_country: "TR",
          outcome: :accepted,
          is_test: false,
          quantity: 4,
          attempt_count: 4,
          sms_segments: 6,
          cost_micros: 480,
          currency: "TRY",
          billable_unit: "segment",
          billable_units: 6
        },
        Map.new(attrs)
      )

    assert {:ok, :recorded} = Relay.Delivery.record_usage(scope, usage)
  end

  defp invoice(attrs \\ %{}) do
    Map.merge(
      %{
        "provider" => "netgsm",
        "invoice_ref" => "INV-" <> TenantFixture.random(),
        "period_start" => Date.to_iso8601(yesterday()),
        "period_end" => Date.to_iso8601(Date.add(yesterday(), 1)),
        "currency" => "TRY",
        "amount_micros" => "480",
        "raw" => %{"invoice" => %{"total" => "0.000480", "currency" => "TRY"}}
      },
      attrs
    )
  end

  defp create(token, body), do: F.request(:post, "/v1/provider_invoices", token, body)

  describe "OP-38 OP-42 provider invoice reconciliation" do
    test "OP-42, OP-38: an invoice that equals the usage cost of its period is matched", ctx do
      usage!(ctx.scope, [])
      body = F.body(create(ctx.token, invoice()), 201)

      assert %{"object" => "provider_invoice", "amount_micros" => "480"} = body
      assert body["raw"] == %{"invoice" => %{"total" => "0.000480", "currency" => "TRY"}}

      assert %{
               "result" => "matched",
               "usage_cost_micros" => "480",
               "usage_units" => 6,
               "unpriced_units" => 0,
               "drift_micros" => "0",
               "drift_bp" => 0
             } = body["reconciliation"]

      got = F.body(F.request(:get, "/v1/provider_invoices/" <> body["id"], ctx.token), 200)
      assert got == body

      list = F.body(F.request(:get, "/v1/provider_invoices", ctx.token), 200)
      assert [%{"id" => id}] = list["data"]
      assert id == body["id"]
    end

    test "OP-42: an invoice above the usage cost drifts and an unpriced row is named", ctx do
      usage!(ctx.scope, [])
      usage!(ctx.scope, destination_country: "DE", cost_micros: nil, currency: nil)
      body = F.body(create(ctx.token, invoice(%{"amount_micros" => "1000"})), 201)

      assert %{
               "result" => "drift",
               "usage_cost_micros" => "480",
               "usage_units" => 12,
               "unpriced_units" => 6,
               "drift_micros" => "520",
               "drift_bp" => 10_833
             } = body["reconciliation"]
    end

    test "OP-42: another provider, channel or period does not count toward the invoice", ctx do
      usage!(ctx.scope, provider: "verimor")
      usage!(ctx.scope, channel: :email, sms_segments: nil, billable_unit: "recipient")
      sms = invoice(%{"channel" => "sms", "amount_micros" => "0"})

      assert %{"result" => "matched", "usage_cost_micros" => "0", "usage_units" => 0} =
               F.body(create(ctx.token, sms), 201)["reconciliation"]

      earlier =
        invoice(%{
          "provider" => "verimor",
          "period_start" => Date.to_iso8601(Date.add(yesterday(), -10)),
          "period_end" => Date.to_iso8601(Date.add(yesterday(), -1))
        })

      assert %{"result" => "drift", "drift_micros" => "480", "drift_bp" => nil} =
               F.body(create(ctx.token, earlier), 201)["reconciliation"]
    end

    test "OP-38: an invoice never changes; its reference again answers it or conflicts", ctx do
      body = invoice()
      first = F.body(create(ctx.token, body), 201)
      assert F.body(create(ctx.token, body), 200)["id"] == first["id"]

      conflict = F.body(create(ctx.token, Map.put(body, "amount_micros", "481")), 409)
      assert conflict["code"] == "resource_conflict"
    end

    test "OP-38: a period must end after it starts and last at most 92 days", ctx do
      start = Date.to_iso8601(yesterday())
      ends = Date.to_iso8601(Date.add(yesterday(), 93))

      for body <- [
            invoice(%{"period_end" => start}),
            invoice(%{"period_end" => ends}),
            invoice(%{"amount_micros" => "99999999999999999999"})
          ] do
        assert F.body(create(ctx.token, body), 422)["code"] == "validation_failed"
      end
    end

    test "TN-15: an invoice of another environment is not found", ctx do
      other = F.body(create(F.token(ctx.other), invoice()), 201)
      missing = F.request(:get, "/v1/provider_invoices/" <> other["id"], ctx.token)
      assert F.body(missing, 404)["code"] == "provider_invoice_not_found"
      assert F.body(F.request(:get, "/v1/provider_invoices", ctx.token), 200)["data"] == []
    end

    test "OP-42: writing a usage day of its period reconciles the invoice again", ctx do
      recorded = F.body(create(ctx.token, invoice()), 201)
      assert recorded["reconciliation"]["result"] == "drift"
      usage!(ctx.scope, [])

      assert {:ok, []} =
               Relay.Repo.in_scope(ctx.scope, fn _status ->
                 Relay.Delivery.Usage.InvoiceStore.check_day(yesterday())
               end)

      got = F.body(F.request(:get, "/v1/provider_invoices/" <> recorded["id"], ctx.token), 200)
      assert got["reconciliation"]["result"] == "matched"
    end
  end
end
