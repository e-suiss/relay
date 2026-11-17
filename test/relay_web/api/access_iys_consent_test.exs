defmodule RelayWeb.Api.AccessIysConsentTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.IysFake, as: Fake
  alias RelayTest.TenantFixture

  @brand 9001
  @environment "00000000-0000-4000-8000-00000000000a"
  @phone "+905321112233"

  setup do
    calendar = {Datasets.installation_scope(), "business_calendar"}
    Datasets.Cache.invalidate(Datasets.Cache, calendar)
    on_exit(fn -> Datasets.Cache.invalidate(Datasets.Cache, calendar) end)
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    start_supervised!({Fake, []})
    :ok = FakeAccess.install!()

    access = TenantFixture.tenant!(platform_product: "access")
    customer = TenantFixture.tenant!()

    %{
      token: F.token(access.live),
      target: customer.live,
      access_tenant: customer.attrs.access_tenant_id
    }
  end

  defp configure!(ctx) do
    var = "RELAY_TEST_IYS_" <> String.upcase(TenantFixture.random())
    System.put_env(var, "iys-password")
    on_exit(fn -> System.delete_env(var) end)
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()

    {:ok, ref} =
      Relay.Secrets.register_ref(ctx.target, :iys_credential, "${#{var}}", 1, digest, actor)

    config = %{
      "mode" => "own",
      "api" => "sandbox",
      "iys_code" => 600_001,
      "integrator_code" => nil,
      "username" => "iys-user",
      "credential_ref_id" => Relay.Id.to_string(ref.id)
    }

    brands = [%{"brand_code" => @brand, "name" => "Marka", "subtenant_id" => nil}]

    {:ok, {:created, _version}} =
      Relay.Iys.in_scope(ctx.target, fn _status ->
        Relay.Iys.put_config(config, brands, nil, TenantFixture.digest(), actor)
      end)

    :ok
  end

  defp consent(ctx, overrides \\ %{}) do
    %{
      "specversion" => "1.0",
      "id" => Ecto.UUID.generate(),
      "source" => "urn:suiss:access:environment:" <> @environment,
      "type" => "relay.message.iys_consent.v1",
      "subject" => "usr_" <> TenantFixture.random(),
      "time" => DateTime.to_iso8601(DateTime.utc_now()),
      "datacontenttype" => "application/json",
      "accesstenant" => ctx.access_tenant,
      "accessenvironment" => @environment,
      "data" =>
        Map.merge(
          %{
            "recipient" => %{"phone" => @phone},
            "channel" => "sms",
            "recipient_type" => "individual",
            "consent" => "approved",
            "source" => "self_service",
            "consent_at" =>
              DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_iso8601()
          },
          overrides
        )
    }
  end

  defp post(ctx, event) do
    auth = RelayTest.Api.auth(ctx.token, :post, "/v1/events")
    headers = [{"content-type", "application/cloudevents+json"} | auth]

    :post
    |> RelayTest.Api.conn("/v1/events", Jason.encode!(event), headers)
    |> RelayTest.Api.call(RelayWeb.Router)
  end

  defp uploads(ctx) do
    {:ok, rows} = Relay.Iys.list_uploads(ctx.target, nil, nil, 50)
    rows
  end

  defp consent_rows(ctx) do
    {:ok, [[count]]} =
      Repo.in_scope(ctx.target, fn _status ->
        Repo.scoped_query!("SELECT count(*) FROM relay.consents", []).rows
      end)

    count
  end

  defp report!(ctx, upload) do
    [[upload_id]] = F.jobs("Relay.Access.IysReport", ctx.target, "upload_id")
    assert upload_id == Relay.Id.to_string(upload["id"])
    args = Map.put(Relay.Scope.to_job_args(ctx.target), "upload_id", upload_id)
    assert Relay.Access.IysReport.perform(%Oban.Job{args: args}) == :ok
    assert_received {:fake_access, :iys_status, report}
    report
  end

  describe "E-109 Access's İYS consent record" do
    test "E-109 E-20: the record is written to İYS through the write path, not to the consent copy, and reported recorded",
         ctx do
      :ok = configure!(ctx)
      event = consent(ctx)

      body = F.body(post(ctx, event), 202)
      assert body["object"] == "iys_consent_record"
      assert body["id"] == event["id"]

      assert [%{"state" => "pending", "consent_status" => "ONAY"} = upload] = uploads(ctx)
      assert upload["source"] == "HS_WEB"
      assert upload["consent_type"] == "MESAJ"
      assert upload["origin"] == "access"
      assert upload["recipient_id"] == nil
      assert consent_rows(ctx) == 0

      assert Relay.Iys.run_upload(ctx.target, upload["id"]) == :done
      assert [%{"state" => "confirmed"}] = uploads(ctx)
      assert consent_rows(ctx) == 0

      report = report!(ctx, upload)
      assert report["status"] == "recorded"
      assert report["tenant"] == ctx.access_tenant
      assert report["environment"] == @environment
      assert report["record"] == event["id"]
      assert is_integer(report["at"])
      refute Map.has_key?(report, "reason")
    end

    test "E-109: the same record sent again opens no second upload", ctx do
      :ok = configure!(ctx)
      event = consent(ctx)

      assert post(ctx, event).status == 202
      assert post(ctx, event).status == 202
      assert length(uploads(ctx)) == 1
    end

    test "E-109: a record İYS refuses for good is reported failed with its reason", ctx do
      :ok = configure!(ctx)
      event = consent(ctx, %{"source" => "import"})

      assert post(ctx, event).status == 202
      [upload] = uploads(ctx)
      assert Relay.Iys.run_upload(ctx.target, upload["id"]) == :done
      assert [%{"state" => "failed"}] = uploads(ctx)

      report = report!(ctx, upload)
      assert report["status"] == "failed"
      assert report["reason"] =~ ~r/\A[a-z][a-z0-9_-]{0,63}\z/
    end

    test "E-109: a tenant without an İYS configuration gets a failed report at once", ctx do
      event = consent(ctx)

      assert post(ctx, event).status == 202
      assert uploads(ctx) == []

      [[record]] = F.jobs("Relay.Access.IysReport", ctx.target, "record")
      assert record == event["id"]

      [[args]] =
        Repo.query!(
          "SELECT args FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>'record' = $2",
          ["Relay.Access.IysReport", record]
        ).rows

      assert Relay.Access.IysReport.perform(%Oban.Job{args: args}) == :ok
      assert_received {:fake_access, :iys_status, report}
      assert report["status"] == "failed"
      assert report["reason"] == "not_configured"
    end

    test "E-109: an address that does not match the channel is a permanent 422", ctx do
      event = consent(ctx, %{"channel" => "email"})
      assert F.body(post(ctx, event), 422)["code"] == "validation_failed"
    end
  end
end
