defmodule Relay.Channels.Push.Policy do
  @moduledoc """
  The push policy of one delivery, decided by the channel step before the provider call and handed to the adapter in `Relay.Channels.Request.push` (CH-19, CH-23, CH-33, CH-65 … CH-67). An adapter only translates it into its wire format; it decides nothing.

    * The platform values come from the `push_priority_map` row of the class at the event's fine-grained priority, clamped to the class ceiling and to the tenant's ceiling (`priority_clamped`, CH-19).
    * The interruption level is the sender's, lowered to the class ceiling (`interruption_clamped`), `critical` only with the tenant's opening, the declared critical template and the recipient's Grant (`critical_not_granted` otherwise, CH-66) and lowered once more to what the platform allows (`interruption_platform_lowered`); without the platform's critical permission the highest level is `time-sensitive` (CH-65 (3)).
    * The collapse keys derive from the notification's subject; a notification without a subject collapses with nothing (CH-23).
    * A `sensitive` template or message flag, the tenant's or category's choice and the regional default decide whether the push goes content-free with neutral lock screen text (CH-33, CH-67).
  """

  alias Relay.Channels.Push.Collapse
  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Interruption
  alias Relay.Channels.Push.Priority

  @classes %{
    "security" => :security,
    "action_required" => :action_required,
    "transactional" => :transactional,
    "operational" => :operational,
    "social" => :social,
    "marketing" => :marketing,
    "system" => :system
  }
  @priorities %{"low" => :low, "normal" => :normal, "high" => :high}

  @typedoc """
  The facts of a delivery: `tenant_id`, `delivery_id`, `message_class`, the event's `priority`, the sender's `interruption`, the notification's `subject_type` and `subject_id`, the template's `sensitivity` and `category`, the message's `sensitive` flag, the tenant's `content_free` choice, the installation `region`, `domestic_only`, the rendered `locale` and `lock_screen_body`, `expires_at`, `now`, the tenant's `tenant_ceiling`, whether the sender is the recipient's `personal_agent` and the `critical` inputs (`enabled`, `declared`, `grant`, `entitled`).
  """
  @type facts :: %{required(atom()) => term()}

  @type t :: %{
          message_class: Priority.message_class(),
          mapping: Priority.mapping(),
          level: Interruption.level() | nil,
          reasons: [atom()],
          collapse: Collapse.keys() | nil,
          content_free: boolean(),
          sensitive: boolean(),
          content_id: String.t(),
          locale: String.t() | nil,
          lock_screen_body: String.t() | nil,
          category: String.t() | nil,
          expires_at: DateTime.t() | nil,
          now: DateTime.t()
        }

  # CH-19
  # CH-23
  # CH-33
  # CH-65
  # CH-66
  # CH-67
  # CH-68
  @doc "Decides the push policy of a delivery from its facts and the priority table snapshot."
  @spec decide(Priority.t(), facts()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def decide(%Priority{} = table, %{} = facts) do
    with {:ok, class} <- class(facts[:message_class]),
         {:ok, mapping} <- lookup(table, class, facts) do
      sensitive = facts[:sensitivity] == "sensitive" or facts[:sensitive] == true
      interruption = Interruption.resolve(interruption(class, mapping, facts, sensitive))

      content_free =
        Content.content_free?(%{
          sensitive: sensitive,
          choice: facts[:content_free],
          region: facts[:region],
          domestic_only: facts[:domestic_only] == true,
          message_class: class
        })

      {:ok,
       %{
         message_class: class,
         mapping: mapping,
         level: interruption.level,
         reasons: mapping.reasons ++ interruption.reasons,
         collapse: collapse(facts, class, mapping),
         content_free: content_free or interruption.content_free,
         sensitive: sensitive,
         content_id: facts[:delivery_id],
         locale: facts[:locale],
         lock_screen_body: facts[:lock_screen_body],
         category: facts[:category],
         expires_at: facts[:expires_at],
         now: facts[:now]
       }}
    end
  end

  defp class(name) do
    case Map.fetch(@classes, to_string(name)) do
      {:ok, class} -> {:ok, class}
      :error -> {:error, Relay.Error.new(:push_class_unmapped, "the class has no push policy")}
    end
  end

  defp lookup(table, class, facts) do
    priority = Map.get(@priorities, to_string(facts[:priority]))
    ceiling = Map.get(@priorities, to_string(facts[:tenant_ceiling]))
    Priority.lookup(table, class, priority, tenant_ceiling: ceiling)
  end

  defp interruption(class, mapping, facts, sensitive) do
    critical = facts[:critical] || %{}
    platform_max = if Map.get(critical, :entitled) == true, do: :critical, else: :time_sensitive

    %{
      message_class: class,
      requested: requested(facts[:interruption]),
      default: mapping.interruption_level,
      ceiling: mapping.interruption_ceiling,
      personal_agent: facts[:personal_agent] == true,
      critical_enabled: Map.get(critical, :enabled, false) == true,
      critical_declared: Map.get(critical, :declared, false) == true,
      grant: Map.get(critical, :grant, :unavailable),
      platform_max: platform_max,
      sensitive: sensitive
    }
  end

  defp requested(nil), do: nil

  defp requested(name) do
    case Interruption.parse(name) do
      {:ok, level} -> level
      :error -> nil
    end
  end

  defp collapse(%{subject_type: type, subject_id: id, tenant_id: tenant}, class, mapping)
       when is_binary(type) and is_binary(id) and is_binary(tenant) do
    subject = %{tenant_id: tenant, subject_type: type, subject_id: id, message_class: class}
    Collapse.keys(subject, mapping.fcm_collapse_key)
  end

  defp collapse(_facts, _class, _mapping), do: nil
end
