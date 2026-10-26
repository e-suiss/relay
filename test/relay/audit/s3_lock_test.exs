defmodule Relay.Audit.S3LockTest do
  use ExUnit.Case, async: true

  alias Relay.Audit.Checkpointer.Publisher.S3

  @until "x-amz-object-lock-retain-until-date"

  defp until(headers), do: headers |> List.keyfind!(@until, 0) |> elem(1)

  defp v2,
    do:
      [:code.priv_dir(:relay), "datasets", "retention_periods", "v2.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

  describe "OP-72 (3) retain-until of a checkpoint object" do
    test "OP-72: the audit retention period wins over a shorter bucket default in days" do
      now = ~U[2026-10-26 08:30:15.654321Z]

      assert S3.lock_headers({"GOVERNANCE", {:days, 1}}, now, 3653) == [
               {"x-amz-object-lock-mode", "GOVERNANCE"},
               {@until, "2036-10-26T08:30:15Z"}
             ]
    end

    test "OP-72: the audit retention period wins over a shorter bucket default in years" do
      now = ~U[2026-10-26 08:30:15Z]

      assert until(S3.lock_headers({"COMPLIANCE", {:years, 1}}, now, 400)) ==
               "2027-11-30T08:30:15Z"

      assert until(S3.lock_headers({"COMPLIANCE", {:years, 10}}, now, 3654)) ==
               "2036-10-27T08:30:15Z"
    end

    test "OP-72: a longer bucket default wins over the audit retention period" do
      now = ~U[2026-10-26 08:30:15Z]

      assert S3.lock_headers({"COMPLIANCE", {:years, 11}}, now, 3653) == [
               {"x-amz-object-lock-mode", "COMPLIANCE"},
               {@until, "2037-10-26T08:30:15Z"}
             ]

      assert until(S3.lock_headers({"GOVERNANCE", {:days, 4000}}, now, 3653)) ==
               "2037-10-08T08:30:15Z"

      assert until(S3.lock_headers({"GOVERNANCE", {:days, 30}}, now, 0)) ==
               "2026-11-25T08:30:15Z"

      assert S3.lock_headers({"GOVERNANCE", {:days, 30}}, now) ==
               S3.lock_headers({"GOVERNANCE", {:days, 30}}, now, 0)
    end

    test "OP-72: equal periods give the same date" do
      now = ~U[2026-10-26 08:30:15Z]

      assert until(S3.lock_headers({"GOVERNANCE", {:days, 400}}, now, 400)) ==
               "2027-11-30T08:30:15Z"
    end

    test "OP-72: the audit period is the longest audit row over every region and sector" do
      assert S3.audit_retention_days(v2()) == 3653

      assert S3.audit_retention_days(%{
               "periods" => [
                 %{
                   "region" => "eu",
                   "sector" => "bank",
                   "retention_class" => "audit",
                   "days" => 1827
                 },
                 %{
                   "region" => "tr",
                   "sector" => "general",
                   "retention_class" => "audit",
                   "days" => 400
                 },
                 %{
                   "region" => "tr",
                   "sector" => "general",
                   "retention_class" => "commercial_message",
                   "days" => 9000
                 }
               ]
             }) == 1827

      assert S3.audit_retention_days(%{
               "periods" => [
                 %{
                   "region" => "tr",
                   "sector" => "general",
                   "retention_class" => "traffic",
                   "days" => 730
                 }
               ]
             }) == 0
    end

    test "OP-72: the audit retention lookup option must be a zero-arity function" do
      opts = RelayDev.ObjectStore.local()

      assert S3.validate(opts) == :ok
      assert S3.validate(Keyword.put(opts, :audit_retention_days, fn -> {:ok, 1} end)) == :ok

      assert {:error, "audit_retention_days must be a zero-arity function"} =
               S3.validate(Keyword.put(opts, :audit_retention_days, 3653))
    end
  end
end

defmodule Relay.Audit.S3LockDatabaseTest do
  use Relay.DataCase, async: true

  alias Relay.Audit.Checkpointer.Publisher.S3

  test "OP-72: the audit retention period comes from the active retention periods version" do
    :ok = RelayTest.TenantFixture.retention_periods!()
    assert S3.audit_retention_days() == {:ok, 3653}
  end
end
