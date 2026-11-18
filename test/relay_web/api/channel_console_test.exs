defmodule RelayWeb.Api.ChannelConsoleTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.EmailResolver
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "channel_parameters"]

  defp forget do
    for name <- @datasets,
        do: :ok = Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)

    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, other: tenant.test, token: F.token(tenant.live)}
  end

  defp account!(scope, fields) do
    id = Relay.Id.generate()

    attrs =
      Map.merge(
        %{
          id: id,
          channel: "email",
          provider: "fake",
          ownership: "shared",
          role: "primary",
          priority: 0,
          in_installation: true,
          transfer_basis: "none",
          settings: %{}
        },
        fields
      )

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    id
  end

  defp pva(id), do: Relay.ExternalId.encode("pva", id)

  defp stream(domain, selector) do
    %{
      "from" => "hello@" <> domain,
      "domain" => domain,
      "selector" => selector,
      "return_path_domain" => "bounce." <> domain,
      "ip_pool" => "pool-" <> selector,
      "queue" => "queue-" <> selector
    }
  end

  describe "CH-6 CH-4 T-25 provider account status" do
    test "CH-6, CH-4, T-25: an account outside the region is flagged with its adapter and its breakers",
         ctx do
      id =
        account!(ctx.scope, %{
          channel: "push",
          provider: "fcm",
          in_installation: false,
          processing_countries: ["US"],
          transfer_basis: "explicit_consent"
        })

      body = F.body(F.request(:get, "/v1/provider_accounts/#{pva(id)}/status", ctx.token), 200)
      region = Relay.Datasets.installation_region()
      residency = body["data_residency"]

      assert residency["reference_region"] == region
      assert residency["declared_processing_countries"] == ["US"]
      assert residency["sends_data_abroad"] == (region != "us")
      if region != "us", do: assert(residency["abroad_countries"] == ["US"])

      assert %{"declared" => true, "adapter_version" => "1.0.0"} = body["adapter"]
      assert body["adapter"]["deprecation_warning"] == (body["adapter"]["deprecations"] != [])

      assert body["circuit_breaker"] == %{
               "provider" => "closed",
               "account" => "closed",
               "observed_by" => "node"
             }
    end

    test "CH-6: an account processed inside the installation sends nothing abroad", ctx do
      id = account!(ctx.scope, %{})
      body = F.body(F.request(:get, "/v1/provider_accounts/#{pva(id)}/status", ctx.token), 200)

      assert body["data_residency"]["sends_data_abroad"] == false
      assert body["data_residency"]["abroad_countries"] == []
    end

    test "CH-6: the other environment's account is not found", ctx do
      id = account!(ctx.other, %{})
      conn = F.request(:get, "/v1/provider_accounts/#{pva(id)}/status", ctx.token)
      assert F.body(conn, 404)["code"] == "provider_account_not_found"
    end
  end

  describe "CH-36 sending domain wizard" do
    test "CH-36, INV-43: each stream lists the records to publish and the findings of live DNS",
         ctx do
      settings = %{
        "streams" => %{
          "transactional" => stream("mail.example.com", "t1"),
          "marketing" => stream("news.example.com", "m1")
        }
      }

      id = account!(ctx.scope, %{settings: settings})

      EmailResolver.put(%{
        {:cname, "bounce.mail.example.com"} => "bounces.relay.test",
        {:txt, "mail.example.com"} => [["v=spf1 -all"]],
        {:txt, "_dmarc.mail.example.com"} => [["v=DMARC1; p=reject"]]
      })

      path = "/v1/provider_accounts/#{pva(id)}/email_domains"
      body = F.body(F.request(:get, path, ctx.token), 200)
      by_stream = Map.new(body["data"], &{&1["stream"], &1})

      transactional = by_stream["transactional"]
      assert transactional["domain"] == "mail.example.com"
      assert transactional["verified"] == false
      assert transactional["spf"]["record"] == "v=spf1 -all"

      records = Map.new(transactional["records"], &{&1["purpose"], &1})
      assert records["return_path"]["value"] == "bounces.relay.test"
      assert records["dkim"]["name"] == "t1._domainkey.mail.example.com"
      assert records["dkim"]["value"] == nil
      assert records["dmarc"]["value"] =~ "np=reject"

      codes = Enum.map(transactional["findings"], & &1["code"])
      assert "dkim_missing" in codes
      refute "return_path_cname_missing" in codes

      marketing_codes = Enum.map(by_stream["marketing"]["findings"], & &1["code"])
      assert "return_path_cname_missing" in marketing_codes
    end

    test "CH-36: an account of another channel has no stream", ctx do
      id = account!(ctx.scope, %{channel: "push", provider: "fcm"})
      path = "/v1/provider_accounts/#{pva(id)}/email_domains"
      assert F.body(F.request(:get, path, ctx.token), 200)["data"] == []
    end
  end

  describe "CH-42 warm-up plans" do
    test "CH-42: the plans are the data set's", ctx do
      body = F.body(F.request(:get, "/v1/email_warmup_plans", ctx.token), 200)
      bundled = Relay.Channels.email_bundled("email_warmup_plans")["plans"]
      assert length(body["data"]) == length(bundled)
    end
  end

  describe "CH-18 paid channel cost" do
    test "CH-18, CH-58: every account of the channel is quoted; a missing price is unpriced, never zero",
         ctx do
      id = account!(ctx.scope, %{channel: "sms"})
      path = "/v1/channel_costs?channel=sms&country=TR&category=marketing&quantity=3"
      body = F.body(F.request(:get, path, ctx.token), 200)

      assert %{"channel" => "sms", "country" => "TR", "quantity" => 3} = body
      assert [row] = body["data"]
      assert row["provider_account_id"] == pva(id)
      assert row["paid"] == true
      assert row["routable"] == false

      if row["priced"] do
        assert row["total_micros"] == row["unit_price_micros"] * 3
      else
        assert row["unit_price_micros"] == nil
        assert row["total_micros"] == nil
      end
    end

    test "CH-58: a WhatsApp quote without a category is unpriced", ctx do
      account!(ctx.scope, %{channel: "whatsapp"})
      conn = F.request(:get, "/v1/channel_costs?channel=whatsapp&country=TR", ctx.token)
      body = F.body(conn, 200)

      assert [%{"source" => "whatsapp_rate_card", "priced" => false}] = body["data"]
      assert body["category"] == nil
      assert body["quantity"] == 1
    end

    test "CH-18: a channel that is not paid is refused", ctx do
      conn = F.request(:get, "/v1/channel_costs?channel=push&country=TR", ctx.token)
      assert F.body(conn, 422)["code"] == "validation_failed"
    end
  end
end
