defmodule Relay.Delivery.UsageRecordTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    %{scope: TenantFixture.tenant!().live}
  end

  defp usage(attrs) do
    Map.merge(
      %{
        id: Relay.Id.generate(),
        usage_day: Date.add(DateTime.to_date(Relay.Clock.utc_now()), -1),
        channel: :sms,
        provider: "netgsm",
        destination_country: "TR",
        outcome: :accepted,
        is_test: false,
        quantity: 10,
        attempt_count: 11,
        sms_segments: 12
      },
      Map.new(attrs)
    )
  end

  defp record(scope, attrs) do
    {:ok, result} = Relay.Delivery.record_usage(scope, usage(attrs))
    result
  end

  describe "C-88 usage records" do
    test "C-88: a closed day is recorded once; the same figures again are a duplicate", %{
      scope: scope
    } do
      assert record(scope, []) == :recorded
      assert record(scope, []) == :duplicate
    end

    test "C-88: other figures for the same key change nothing", %{scope: scope} do
      :recorded = record(scope, [])
      assert record(scope, quantity: 99) == :conflict
    end

    test "C-88: test traffic is a separate row", %{scope: scope} do
      :recorded = record(scope, [])
      assert record(scope, is_test: true) == :recorded
    end

    test "C-88: the current UTC day is still open", %{scope: scope} do
      assert record(scope, usage_day: DateTime.to_date(Relay.Clock.utc_now())) == :day_open
    end

    test "C-88: usage rows cannot be updated", %{scope: scope} do
      :recorded = record(scope, [])

      assert {:error, %Postgrex.Error{}} =
               Repo.in_scope(scope, fn _ ->
                 case Repo.query("UPDATE relay.usage_records SET quantity = 0", []) do
                   {:ok, result} -> result
                   {:error, error} -> Repo.rollback(error)
                 end
               end)
    end
  end
end
