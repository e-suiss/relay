defmodule Relay.Channels.Push.PriorityTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Priority
  alias Relay.Datasets.Package

  @dir "priv/datasets/push_priority_map"

  @fields [
    :apns_priority,
    :interruption_level,
    :fcm_priority,
    :web_push_urgency,
    :android_importance
  ]

  defp content, do: @dir |> Path.join("v1.json") |> File.read!() |> Jason.decode!()

  defp snapshot, do: Priority.new(content(), Relay.Id.generate())

  defp row(class, priority) do
    {:ok, m} = Priority.lookup(snapshot(), class, priority)
    @fields |> Enum.map(&Map.fetch!(m, &1)) |> List.to_tuple()
  end

  describe "CH-19 platform mapping table" do
    test "CH-19: the bundled version is valid and consistent" do
      assert {:ok, datasets} = Package.read(Package.root())
      assert "push_priority_map" in Enum.map(datasets, & &1.name)
      assert Priority.validate(content()) == :ok
      assert Priority.dataset() == "push_priority_map"
    end

    test "CH-19: every cell is the spec table's value" do
      assert row(:security, :low) == {5, :time_sensitive, :normal, :high, "HIGH"}
      assert row(:security, :normal) == {10, :time_sensitive, :high, :high, "HIGH"}
      assert row(:security, :high) == {10, :time_sensitive, :high, :high, "HIGH"}
      assert row(:action_required, :normal) == {10, :time_sensitive, :high, :high, "HIGH"}
      assert row(:transactional, :low) == {5, :active, :normal, :normal, "DEFAULT"}
      assert row(:transactional, :normal) == {10, :active, :normal, :normal, "DEFAULT"}
      assert row(:transactional, :high) == {10, :active, :high, :normal, "DEFAULT"}
      assert row(:operational, :normal) == {10, :active, :normal, :normal, "DEFAULT"}
      assert row(:social, :low) == {5, :passive, :normal, :low, "LOW"}
      assert row(:social, :normal) == {5, :active, :normal, :low, "LOW"}
      assert row(:marketing, :normal) == {5, :passive, :normal, :low, "LOW"}
      assert row(:system, :low) == {5, nil, :normal, nil, nil}

      {:ok, system} = Priority.lookup(snapshot(), :system, nil)
      assert system.apns_push_type == :background
      assert system.interruption_ceiling == nil
    end

    test "CH-19: a priority above the class ceiling is lowered and recorded" do
      assert {:ok, %{priority: :normal, reasons: [:priority_clamped]}} =
               Priority.lookup(snapshot(), :marketing, :high)

      assert {:ok, %{priority: :low, apns_priority: 5, reasons: [:priority_clamped]}} =
               Priority.lookup(snapshot(), :system, :normal)

      assert {:ok, %{priority: :normal, reasons: []}} =
               Priority.lookup(snapshot(), :operational, nil)

      assert {:ok, %{priority: :low, reasons: []}} = Priority.lookup(snapshot(), :system, nil)
    end

    test "CH-19: a tenant can only lower the priority" do
      assert {:ok, %{priority: :normal, fcm_priority: :high, reasons: [:priority_clamped]}} =
               Priority.lookup(snapshot(), :security, :high, tenant_ceiling: :normal)

      assert {:ok, %{priority: :normal, reasons: [:priority_clamped]}} =
               Priority.lookup(snapshot(), :marketing, :high, tenant_ceiling: :high)

      assert {:ok, %{priority: :low, apns_priority: 5}} =
               Priority.lookup(snapshot(), :transactional, nil, tenant_ceiling: :low)
    end

    test "OP-65 (4): the lookup records the version it used" do
      id = Relay.Id.generate()
      snapshot = Priority.new(content(), id)
      assert {:ok, %{version_id: ^id}} = Priority.lookup(snapshot, :social, nil)
    end

    test "CH-23: FCM collapses on a fixed key per class" do
      classes = Priority.new(content(), "v").classes
      keys = for {_class, row} <- classes, do: row.fcm_collapse_key
      assert length(Enum.uniq(keys)) == 7
    end

    test "CH-27: the HMS classification is fixed by class" do
      for class <- [:security, :transactional, :operational, :action_required] do
        {:ok, m} = Priority.lookup(snapshot(), class, nil)
        assert {m.hms_classification, m.hms_importance} == {"service_communication", "NORMAL"}
      end

      for class <- [:marketing, :social] do
        {:ok, m} = Priority.lookup(snapshot(), class, nil)
        assert {m.hms_classification, m.hms_importance} == {"information_marketing", "LOW"}
      end
    end

    test "CH-19: validation refuses a missing class or cells above the ceiling" do
      [first | rest] = content()["classes"]
      assert {:error, %{code: :invalid_content}} = Priority.validate(%{"classes" => rest})

      extra = put_in(first, ["priority_ceiling"], "normal")
      invalid = %{"classes" => [extra | rest]}
      assert {:error, %{code: :invalid_content}} = Priority.validate(invalid)
    end

    test "CH-19: no cell is marked measured before a device measurement" do
      assert Enum.all?(content()["classes"], &(&1["measured_at"] == nil))
    end
  end
end
