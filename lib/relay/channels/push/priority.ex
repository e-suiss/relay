defmodule Relay.Channels.Push.Priority do
  @moduledoc """
  The `push_priority_map` data set as a snapshot, and its pure lookup (CH-19, INV-16, API-22). Platform priority is derived from one table, keyed by the message class and the fine-grained priority clamped to the class ceiling: APNs `apns-priority` and push type, the default iOS interruption level, FCM priority, Web Push `Urgency`, the default Android channel importance, the HMS classification (CH-27) and the fixed FCM collapse key (CH-23). A tenant can only lower: its ceiling applies under the class ceiling and never above it.

  The cells are derived from platform documentation and are corrected by a data change once measured on the platform test devices (CH-78); the snapshot carries the version identifier the decision records (OP-65 (4)).
  """

  alias Relay.Channels.Push.Interruption

  @classes ~w(security action_required transactional operational social marketing system)a
  @class_names Map.new(@classes, &{Atom.to_string(&1), &1})
  @rank %{low: 0, normal: 1, high: 2}
  @priorities %{"low" => :low, "normal" => :normal, "high" => :high}
  @fcm %{"normal" => :normal, "high" => :high}
  @urgency %{"very-low" => :very_low, "low" => :low, "normal" => :normal, "high" => :high}
  @push_types %{"alert" => :alert, "background" => :background}

  @enforce_keys [:version_id, :classes]
  defstruct [:version_id, :classes]

  @type message_class ::
          :security
          | :action_required
          | :transactional
          | :operational
          | :social
          | :marketing
          | :system
  @type priority :: :low | :normal | :high

  @typedoc "One class row of the table."
  @type row :: %{
          priority_ceiling: priority(),
          interruption_ceiling: Interruption.level() | nil,
          cells: %{optional(priority()) => cell()},
          apns_push_type: :alert | :background,
          web_push_urgency: :very_low | :low | :normal | :high | nil,
          android_importance: String.t() | nil,
          hms_classification: String.t() | nil,
          hms_importance: String.t() | nil,
          fcm_collapse_key: String.t(),
          measured_at: String.t() | nil
        }

  @typedoc "One cell: the platform values of a class at a fine-grained priority."
  @type cell :: %{
          apns_priority: 1 | 5 | 10,
          interruption_level: Interruption.level() | nil,
          fcm_priority: :normal | :high
        }

  @typedoc "The platform values of one message."
  @type mapping :: %{
          message_class: message_class(),
          priority: priority(),
          apns_priority: 1 | 5 | 10,
          apns_push_type: :alert | :background,
          interruption_level: Interruption.level() | nil,
          interruption_ceiling: Interruption.level() | nil,
          fcm_priority: :normal | :high,
          web_push_urgency: :very_low | :low | :normal | :high | nil,
          android_importance: String.t() | nil,
          hms_classification: String.t() | nil,
          hms_importance: String.t() | nil,
          fcm_collapse_key: String.t(),
          reasons: [:priority_clamped],
          version_id: Relay.Id.t()
        }

  @type t :: %__MODULE__{version_id: Relay.Id.t(), classes: %{message_class() => row()}}

  @doc "The name of the data set."
  @spec dataset() :: String.t()
  def dataset, do: "push_priority_map"

  # CH-19
  # OP-65 (4)
  @doc "Builds a snapshot from the content of a `push_priority_map` version and its identifier."
  @spec new(map(), Relay.Id.t()) :: t()
  def new(%{"classes" => classes}, version_id) when is_binary(version_id) do
    rows = Map.new(classes, &{Map.fetch!(@class_names, &1["message_class"]), row(&1)})
    %__MODULE__{version_id: version_id, classes: rows}
  end

  defp row(row) do
    %{
      priority_ceiling: Map.fetch!(@priorities, row["priority_ceiling"]),
      interruption_ceiling: level(row["interruption_ceiling"]),
      cells: Map.new(row["priorities"], &cell/1),
      apns_push_type: Map.fetch!(@push_types, row["apns_push_type"]),
      web_push_urgency: urgency(row["web_push_urgency"]),
      android_importance: row["android_importance"],
      hms_classification: row["hms_classification"],
      hms_importance: row["hms_importance"],
      fcm_collapse_key: row["fcm_collapse_key"],
      measured_at: row["measured_at"]
    }
  end

  defp cell({priority, cell}) do
    value = %{
      apns_priority: cell["apns_priority"],
      interruption_level: level(cell["interruption_level"]),
      fcm_priority: Map.fetch!(@fcm, cell["fcm_priority"])
    }

    {Map.fetch!(@priorities, priority), value}
  end

  defp level(nil), do: nil
  defp level(name), do: Interruption.parse!(name)

  defp urgency(nil), do: nil
  defp urgency(name), do: Map.fetch!(@urgency, name)

  # CH-19
  # INV-16
  # API-22
  @doc """
  The platform values of a message of `message_class` at the requested fine-grained `priority` (`nil` is `normal`). The priority is clamped to the class ceiling and to the tenant's `:tenant_ceiling` option, which can only lower it; a lowered requested value records `priority_clamped`.
  """
  @spec lookup(t(), message_class(), priority() | nil, keyword()) ::
          {:ok, mapping()} | {:error, Relay.Error.t()}
  def lookup(%__MODULE__{} = s, message_class, priority, opts \\ []) do
    with {:ok, row} <- fetch(s, message_class) do
      tenant = Keyword.get(opts, :tenant_ceiling)
      ceiling = lowest(row.priority_ceiling, tenant)
      requested = priority || :normal
      applied = lowest(requested, ceiling)
      cell = cell_at(row.cells, applied)
      clamped = priority != nil and applied != priority

      {:ok,
       %{
         message_class: message_class,
         priority: applied,
         apns_priority: cell.apns_priority,
         apns_push_type: row.apns_push_type,
         interruption_level: cell.interruption_level,
         interruption_ceiling: row.interruption_ceiling,
         fcm_priority: cell.fcm_priority,
         web_push_urgency: row.web_push_urgency,
         android_importance: row.android_importance,
         hms_classification: row.hms_classification,
         hms_importance: row.hms_importance,
         fcm_collapse_key: row.fcm_collapse_key,
         reasons: if(clamped, do: [:priority_clamped], else: []),
         version_id: s.version_id
       }}
    end
  end

  defp fetch(%__MODULE__{classes: classes}, message_class) do
    case Map.fetch(classes, message_class) do
      {:ok, row} ->
        {:ok, row}

      :error ->
        {:error, Relay.Error.new(:push_class_unmapped, "the class has no push priority row")}
    end
  end

  defp lowest(priority, nil), do: priority

  defp lowest(priority, ceiling) when is_map_key(@rank, priority) and is_map_key(@rank, ceiling),
    do: if(@rank[priority] > @rank[ceiling], do: ceiling, else: priority)

  defp cell_at(cells, priority) do
    case Map.fetch(cells, priority) do
      {:ok, cell} -> cell
      :error -> cell_at(cells, lower(priority))
    end
  end

  defp lower(:high), do: :normal
  defp lower(:normal), do: :low

  # CH-19
  @doc "Checks the rules a JSON Schema cannot express: every class appears once and has a cell at each priority up to its ceiling and none above."
  @spec validate(map()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{"classes" => classes}) when is_list(classes) do
    names = Enum.map(classes, & &1["message_class"])

    cond do
      Enum.sort(names) != Enum.sort(Map.keys(@class_names)) ->
        invalid("every message class appears exactly once")

      not Enum.all?(classes, &cells_match_ceiling?/1) ->
        invalid("a class has cells exactly up to its priority ceiling")

      true ->
        :ok
    end
  end

  def validate(_content), do: invalid("not a push priority map")

  defp cells_match_ceiling?(%{"priority_ceiling" => ceiling, "priorities" => cells}) do
    rank = @rank[Map.fetch!(@priorities, ceiling)]
    expected = for {name, p} <- @priorities, @rank[p] <= rank, do: name
    Enum.sort(Map.keys(cells)) == Enum.sort(expected)
  end

  defp invalid(message), do: {:error, Relay.Error.new(:invalid_content, message)}
end
