defmodule Relay.TenantLifecycle.ClosureTest do
  use Relay.DataCase, async: false

  import Relay.MaintenanceCase,
    only: [tenant!: 0, scoped: 3, recipient!: 1, subject_key!: 3, rows!: 2]

  alias Relay.TenantLifecycle
  alias Relay.TenantLifecycle.ExportStore.S3

  @actor %Relay.Actor{
    kind: :installation_operator,
    ref: "platform-op",
    on_behalf_of_ref: "platform-op",
    access_record_ref: "stepup-1"
  }

  setup do
    RelayTest.TenantFixture.retention_periods!()
    tenant = tenant!()
    keys = tenant.keys["live"]

    recipient =
      scoped(tenant.id, "live", fn ->
        {recipient, _profile_key} = recipient!(keys)
        _ = subject_key!(recipient, "delivery_record", keys.wrap)
        _ = subject_key!(recipient, "preference", keys.wrap)
        recipient
      end)

    test_pid = self()

    Req.Test.stub(S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:put, conn.method, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{tenant: tenant, recipient: recipient}
  end

  defp status(tenant_id) do
    [[status]] = rows!("SELECT status FROM relay.tenants WHERE id = $1", [tenant_id])
    status
  end

  defp actions(tenant_id, environment) do
    scope = Relay.Scope.new!(tenant_id, environment)
    for row <- RelayTest.TenantFixture.audit!(scope, nil), do: row["action"]
  end

  defp keys(tenant_id, environment) do
    scoped(tenant_id, environment, fn ->
      "SELECT purpose, state FROM relay.tenant_keys ORDER BY purpose"
      |> rows!([])
      |> Enum.map(&List.to_tuple/1)
    end)
  end

  defp subject_keys(tenant_id, recipient) do
    scoped(tenant_id, "live", fn ->
      "SELECT retention_class, state FROM relay.subject_keys WHERE recipient_id = $1"
      |> rows!([recipient])
      |> Map.new(&List.to_tuple/1)
    end)
  end

  @jobs "SELECT args FROM relay_queue.oban_jobs WHERE worker = 'Relay.TenantLifecycle.ClosureJob' AND args->>'tenant_id' = $1"

  defp job_args(tenant_id), do: rows!(@jobs, [Relay.Id.to_string(tenant_id)])

  defp exported(tenant) do
    assert [[args]] = job_args(tenant.id)
    assert :ok = Relay.TenantLifecycle.ClosureJob.perform(%Oban.Job{args: args})
    {:ok, closure} = TenantLifecycle.closure(tenant.id)
    closure
  end

  defp puts(acc \\ []) do
    receive do
      {:put, "PUT", path, body} -> puts([{path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "OP-86 tenant closure" do
    test "OP-86: the request closes the tenant, queues its export and is audited", %{
      tenant: tenant
    } do
      assert {:ok, %{"state" => "exporting", "formats" => ["jsonl", "csv"]}} =
               TenantLifecycle.request_closure(
                 tenant.id,
                 %{reason: "contract ended"},
                 @actor,
                 "stepup-1"
               )

      assert status(tenant.id) == "closed"
      assert "tenant.closed" in actions(tenant.id, "live")

      assert [[%{"environment" => "live", "closure_id" => _id}]] = job_args(tenant.id)

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               TenantLifecycle.request_closure(tenant.id, %{reason: "again"}, @actor, nil)
    end

    test "OP-86: an unknown format or a missing reason is refused", %{tenant: tenant} do
      assert {:error, %Relay.Error{code: :validation_failed}} =
               TenantLifecycle.request_closure(
                 tenant.id,
                 %{reason: "x", formats: ["xml"]},
                 @actor,
                 nil
               )

      assert {:error, %Relay.Error{code: :validation_failed}} =
               TenantLifecycle.request_closure(tenant.id, %{reason: ""}, @actor, nil)

      assert status(tenant.id) == "active"
    end

    test "OP-86: the export writes JSON lines and CSV of both environments with a manifest", %{
      tenant: tenant
    } do
      {:ok, _closure} =
        TenantLifecycle.request_closure(tenant.id, %{reason: "contract ended"}, @actor, nil)

      closure = exported(tenant)
      assert closure["state"] == "export_ready"
      files = closure["files"]
      assert length(files) == 2 * 4 * 2

      for file <- files do
        assert file["format"] in ["jsonl", "csv"]
        assert file["environment"] in ["live", "test"]
        assert file["url"] =~ "X-Amz-Signature="
        assert file["url"] =~ "X-Amz-Expires=86400"
        assert file["sha256"] =~ ~r/^[0-9a-f]{64}$/
      end

      assert [%{"rows" => 1}, %{"rows" => 1}] =
               Enum.filter(files, &(&1["kind"] == "subscribers" and &1["environment"] == "live"))

      prefix = "/relay-exports/" <> closure["export_prefix"]
      written = puts()
      assert length(written) == length(files) + 1
      assert Enum.all?(written, fn {path, _body} -> String.starts_with?(path, prefix) end)

      assert {_path, body} = List.last(written)
      assert %{"version" => 1, "files" => listed} = Jason.decode!(body)
      assert length(listed) == length(files)

      first_part = prefix <> "live/subscribers/part-00001.jsonl"
      [{_first, first}] = Enum.filter(written, fn {path, _} -> path == first_part end)

      assert [%{"id" => "sub_" <> _, "state" => "active"}] =
               first |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert "tenant.export_ready" in actions(tenant.id, "live")
    end

    test "OP-86: keys go only 30 days after the export or after the tenant's confirmation", %{
      tenant: tenant,
      recipient: recipient
    } do
      {:ok, _closure} =
        TenantLifecycle.request_closure(tenant.id, %{reason: "contract ended"}, @actor, nil)

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               TenantLifecycle.shred(tenant.id, @actor, "stepup-2")

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               TenantLifecycle.confirm_closure(tenant.id, "access-record-9", @actor)

      _closure = exported(tenant)

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               TenantLifecycle.shred(tenant.id, @actor, "stepup-2")

      assert {:ok, %{"confirmation_ref" => "access-record-9"}} =
               TenantLifecycle.confirm_closure(tenant.id, "access-record-9", @actor)

      assert {:ok, %{"state" => "shredded", "shredded" => counts}} =
               TenantLifecycle.shred(tenant.id, @actor, "stepup-2")

      assert counts.keys >= 2
      assert counts.restricted >= 1

      assert keys(tenant.id, "live") == [{"data", "destroyed"}, {"dek_wrap", "active"}]
      assert keys(tenant.id, "test") == [{"data", "destroyed"}, {"dek_wrap", "destroyed"}]

      assert subject_keys(tenant.id, recipient) == %{
               "recipient_profile" => "destroyed",
               "preference" => "destroyed",
               "delivery_record" => "restricted"
             }

      live = actions(tenant.id, "live")

      for action <- ~w(tenant.closed tenant.export_ready tenant.closure_confirmed
                       tenant.shred_started tenant.shredded),
          do: assert(action in live, action)

      assert "tenant.shredded" in actions(tenant.id, "test")

      assert {:ok, %{"state" => "shredded"}} =
               TenantLifecycle.shred(tenant.id, @actor, "stepup-3")
    end

    test "OP-26: an active legal hold on the tenant stops the destruction", %{tenant: tenant} do
      scoped(tenant.id, "live", fn ->
        assert [["placed"]] =
                 rows!(
                   "SELECT relay_fn.legal_hold_place($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                   [
                     Relay.Id.generate(),
                     "tenant",
                     nil,
                     "regulator request",
                     :crypto.strong_rand_bytes(32),
                     "system",
                     "relay:test",
                     "relay",
                     nil
                   ]
                 )
      end)

      {:ok, _closure} =
        TenantLifecycle.request_closure(tenant.id, %{reason: "contract ended"}, @actor, nil)

      _closure = exported(tenant)
      {:ok, _confirmed} = TenantLifecycle.confirm_closure(tenant.id, "access-record-9", @actor)

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               TenantLifecycle.shred(tenant.id, @actor, "stepup-2")

      assert keys(tenant.id, "live") == [{"data", "active"}, {"dek_wrap", "active"}]
    end

    test "OP-86: an export file is JSON lines with one object per row, or CSV with a header" do
      columns = ["id", "state"]
      rows = [["sub_1", "active"], ["sub_2", "deleted"]]

      assert IO.iodata_to_binary(Relay.TenantLifecycle.Closure.encode("jsonl", columns, rows)) ==
               ~s({"id":"sub_1","state":"active"}\n{"id":"sub_2","state":"deleted"}\n)

      assert IO.iodata_to_binary(Relay.TenantLifecycle.Closure.encode("csv", columns, rows)) ==
               "id,state\r\nsub_1,active\r\nsub_2,deleted\r\n"
    end
  end
end
