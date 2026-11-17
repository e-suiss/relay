defmodule RelayWeb.Api.ComplianceSettingsTest do
  use Relay.DataCase, async: false

  alias Relay.Policy.Live
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @path "/v1/compliance_settings"

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp refusal(country, kinds), do: %{"country" => country, "consent_kinds" => kinds}

  defp put(token, refusals), do: F.request(:put, @path, token, %{"refusals" => refusals})

  describe "PC-40 INV-17 the tenant's tightening of the compliance table" do
    test "PC-40: a tenant refuses nothing until it sets its own refusals", ctx do
      view = F.body(F.request(:get, @path, ctx.token), 200)

      assert %{"object" => "compliance_settings", "version" => nil, "refusals" => []} = view
      assert is_list(view["installation_refusals"])
      assert %{refusals: refusals} = Live.compliance(ctx.scope)
      assert refusals == %{}
    end

    test "PC-40, INV-17: a refusal is published as a version and is in force for the lattice",
         ctx do
      view = F.body(put(ctx.token, [refusal("EU", ["soft_opt_in"])]), 200)

      assert %{"version" => 1, "refusals" => [%{"country" => "EU"}]} = view
      assert %{refusals: %{"EU" => ["soft_opt_in"]}} = Live.compliance(ctx.scope)

      other = TenantFixture.tenant!()
      assert %{refusals: refusals} = Live.compliance(other.live)
      assert refusals == %{}

      reset = F.body(put(ctx.token, []), 200)
      assert %{"version" => 2, "refusals" => []} = reset
      assert %{refusals: cleared} = Live.compliance(ctx.scope)
      assert cleared == %{}
    end

    test "INV-17: only soft opt-in and legitimate interest can be refused and nothing can loosen a row",
         ctx do
      for kind <- ["explicit_opt_in", "none"] do
        assert put(ctx.token, [refusal("TR", [kind])]).status == 422
      end

      loosen = Map.put(refusal("TR", ["soft_opt_in"]), "accept", ["none"])
      assert put(ctx.token, [loosen]).status == 422

      window = %{"refusals" => [], "legal_window" => %{"from" => "00:00", "to" => "23:59"}}
      assert F.request(:put, @path, ctx.token, window).status == 422

      twice = [refusal("DE", ["soft_opt_in"]), refusal("DE", ["legitimate_interest"])]
      problem = F.body(put(ctx.token, twice), 422)
      assert [%{"pointer" => "/refusals/1/country", "code" => "conflict"}] = problem["errors"]

      view = F.body(F.request(:get, @path, ctx.token), 200)
      assert view["version"] == nil
    end
  end
end
