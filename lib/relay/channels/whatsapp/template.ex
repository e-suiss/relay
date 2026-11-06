defmodule Relay.Channels.Whatsapp.Template do
  @moduledoc """
  The lifecycle of WhatsApp templates (CH-57, TP-23).

    * A template is an immutable artifact named with its version (`order_shipped_v3`): new content is a new Meta template name and going back to an older version is going back to its older name. A registration of a known name and language with other content is refused.
    * Relay keeps its own lifecycle, `pending_approval` → `approved`, next to Meta's status: `APPROVED` and `REINSTATED` approve; `REJECTED` rejects with Meta's own reason; `PAUSED` pauses; `DISABLED`, `PENDING_DELETION`, `DELETED`, `ARCHIVED` and `LIMIT_EXCEEDED` disable; `PENDING` and `IN_APPEAL` wait for approval; `FLAGGED` keeps the state. Only an approved template is sent: a pending, rejected, paused or disabled one is not (`sendable?/1`). The approval time is a target, never an SLA.
    * The Relay message class maps to a fixed WhatsApp category: `security` → authentication, `transactional`, `operational` and `action_required` → utility, `marketing` and `social` → marketing. When Meta changes a template's category (`template_category_update`) Relay's class stays; the change is a drift reported to the tenant and the cost follows Meta's category (`drift/2`).
    * Meta limits edits of an approved template (TP-23); `edit_quota/3` says how many remain and, when none, why and when the next one opens.
    * The preview shows the text Meta approved, with the parameters in place, and warns when the parameters and the approved placeholders differ (`preview/2`).
  """

  @statuses ~w(pending_approval approved rejected paused disabled)
  @categories ~w(authentication utility marketing)
  @meta %{
    "APPROVED" => "approved",
    "REINSTATED" => "approved",
    "REJECTED" => "rejected",
    "PAUSED" => "paused",
    "DISABLED" => "disabled",
    "PENDING_DELETION" => "disabled",
    "DELETED" => "disabled",
    "ARCHIVED" => "disabled",
    "LIMIT_EXCEEDED" => "disabled",
    "PENDING" => "pending_approval",
    "IN_APPEAL" => "pending_approval"
  }
  @classes %{
    "security" => "authentication",
    "transactional" => "utility",
    "operational" => "utility",
    "action_required" => "utility",
    "marketing" => "marketing",
    "social" => "marketing"
  }
  @placeholder ~r/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/
  @day_ms 24 * 60 * 60 * 1000

  @type quota :: %{
          remaining: non_neg_integer(),
          next_at: DateTime.t() | nil,
          reason: :daily | :monthly | nil
        }

  @doc "The Relay lifecycle states of a WhatsApp template."
  @spec statuses() :: [String.t(), ...]
  def statuses, do: @statuses

  @doc "The WhatsApp template categories."
  @spec categories() :: [String.t(), ...]
  def categories, do: @categories

  # CH-57
  @doc "The fixed WhatsApp category of a Relay message class."
  @spec category(String.t()) :: {:ok, String.t()} | {:error, :unknown_class}
  def category(message_class) do
    case Map.fetch(@classes, message_class) do
      {:ok, category} -> {:ok, category}
      :error -> {:error, :unknown_class}
    end
  end

  # TP-23
  @doc "The Relay state a Meta template status leads to from `current`; a status that does not change the state (`FLAGGED`, an unknown one) keeps it."
  @spec transition(String.t(), String.t() | nil) :: String.t()
  def transition(current, meta_status) when current in @statuses,
    do: Map.get(@meta, meta_status, current)

  # CH-57
  # TP-23
  @doc "Returns true when a template in this state may be sent: only an approved one."
  @spec sendable?(String.t()) :: boolean()
  def sendable?(status), do: status == "approved"

  # CH-57
  @doc "Compares the category Meta set with the category of the Relay class: `:none`, or the drift and whether it raises the cost (utility or authentication becoming marketing)."
  @spec drift(String.t(), String.t() | nil) :: :none | {:drift, %{required(atom()) => term()}}
  def drift(_expected, nil), do: :none
  def drift(expected, expected), do: :none

  def drift(expected, actual) do
    {:drift, %{expected: expected, actual: actual, cost_up?: actual == "marketing"}}
  end

  # TP-23
  @doc "The edits left on an approved template at `now` from its earlier edit times, under `limits` (`per_24h`, `per_30d`); with none left, why and when the next edit opens."
  @spec edit_quota([DateTime.t()], map(), DateTime.t()) :: quota()
  def edit_quota(edits, %{"per_24h" => daily, "per_30d" => monthly}, %DateTime{} = now) do
    day = within(edits, now, @day_ms)
    month = within(edits, now, 30 * @day_ms)

    cond do
      length(month) >= monthly ->
        %{remaining: 0, next_at: reopens(month, monthly, 30 * @day_ms), reason: :monthly}

      length(day) >= daily ->
        %{remaining: 0, next_at: reopens(day, daily, @day_ms), reason: :daily}

      true ->
        %{remaining: monthly - length(month), next_at: nil, reason: nil}
    end
  end

  defp within(edits, now, window_ms) do
    edits
    |> Enum.filter(&(DateTime.diff(now, &1, :millisecond) < window_ms))
    |> Enum.sort(DateTime)
  end

  defp reopens(sorted, limit, window_ms) do
    sorted
    |> Enum.at(length(sorted) - limit)
    |> DateTime.add(window_ms, :millisecond)
  end

  # TP-23
  @doc "The approved text of a template's components with the parameters in place: the header, body and footer text, and the placeholders that have no parameter (`missing`) and the parameters that have no placeholder (`extra`); a template whose `missing` or `extra` is not empty diverges from the cell."
  @spec preview([map()], [map()]) :: %{
          header: String.t() | nil,
          body: String.t() | nil,
          footer: String.t() | nil,
          missing: [String.t()],
          extra: [String.t()]
        }
  def preview(components, parameters) when is_list(components) and is_list(parameters) do
    values = Map.new(parameters, &{to_string(&1["name"]), to_string(&1["value"])})
    texts = Map.new(components, &{String.downcase(to_string(&1["type"])), text(&1["text"])})
    placeholders = texts |> Map.values() |> Enum.flat_map(&names/1) |> Enum.uniq()

    %{
      header: fill(texts["header"], values),
      body: fill(texts["body"], values),
      footer: texts["footer"],
      missing: Enum.reject(placeholders, &Map.has_key?(values, &1)),
      extra: values |> Map.keys() |> Enum.reject(&(&1 in placeholders)) |> Enum.sort()
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp names(nil), do: []
  defp names(text), do: Enum.map(Regex.scan(@placeholder, text), fn [_, name] -> name end)

  defp fill(nil, _values), do: nil

  defp fill(text, values) do
    Regex.replace(@placeholder, text, fn whole, name -> Map.get(values, name, whole) end)
  end

  # CH-57
  @doc "The digest of a template's content (its components in canonical form), which makes a registration immutable."
  @spec digest([map()]) :: <<_::256>>
  def digest(components) when is_list(components),
    do: :crypto.hash(:sha256, Relay.Canonical.encode!(components))
end
