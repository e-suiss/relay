defmodule Relay.Channels.Push.Interruption do
  @moduledoc """
  The interruption level contract (CH-65 … CH-68, E-77). A notification carries one of four levels, `passive`, `active`, `time-sensitive` and `critical`. The sender chooses it in `interruption`; without it the level comes from the priority table. Relay only lowers a level, never raises it:

  1. The level is lowered to the class ceiling (`security` and `action_required` → `time-sensitive`; `transactional`, `operational` and `social` → `active`; `marketing` → `passive`; `system` carries no visible level) and the lowering records `interruption_clamped`. A `transactional` notification from the recipient's own personal agent has the ceiling `time-sensitive` (CH-68).
  2. `critical` is never a ceiling. It needs the tenant's opening (CH-20), a declared critical template or sender and the recipient's explicit Grant, asked through `Relay.Channels.Push.CriticalGrant` only when the first two hold; any other outcome delivers at the class ceiling and records `critical_not_granted` (fail-closed, CH-66).
  3. When the platform does not allow the level (no Critical Alerts entitlement, no Android DND access), the notification goes one or more levels lower and records `interruption_platform_lowered`; it is never dropped.
  4. A `sensitive` notification shows only neutral text on the lock screen and goes content-free, whatever its level (CH-67).
  """

  alias Relay.Channels.Push.CriticalGrant

  @levels [:passive, :active, :time_sensitive, :critical]
  @rank %{passive: 0, active: 1, time_sensitive: 2, critical: 3}
  @names %{
    "passive" => :passive,
    "active" => :active,
    "time-sensitive" => :time_sensitive,
    "critical" => :critical
  }
  @urgency %{passive: :low, active: :normal, time_sensitive: :high, critical: :high}
  @urgency_rank %{very_low: 0, low: 1, normal: 2, high: 3}

  @type level :: :passive | :active | :time_sensitive | :critical
  @type reason :: :interruption_clamped | :critical_not_granted | :interruption_platform_lowered

  @typedoc """
  The inputs of one notification: its class, the sender's `requested` level, the table's `default` level and `ceiling` (`Relay.Channels.Push.Priority.lookup/4`), whether the sender is the recipient's own personal agent, the tenant's critical opening and the template's critical declaration, the Grant decision or a function that asks for it, the highest level the platform allows and the `sensitive` flag.
  """
  @type input :: %{
          required(:message_class) => atom(),
          required(:requested) => level() | nil,
          required(:default) => level() | nil,
          required(:ceiling) => level() | nil,
          optional(:personal_agent) => boolean(),
          optional(:critical_enabled) => boolean(),
          optional(:critical_declared) => boolean(),
          optional(:grant) => CriticalGrant.decision() | (-> CriticalGrant.decision()),
          optional(:platform_max) => level(),
          optional(:sensitive) => boolean()
        }

  @type result :: %{
          level: level() | nil,
          reasons: [reason()],
          sensitive: boolean(),
          lock_screen: :neutral | :content,
          content_free: boolean()
        }

  @doc "The four levels, lowest first."
  @spec levels() :: [level(), ...]
  def levels, do: @levels

  # CH-65
  @doc "Reads a level from its wire name (`time-sensitive`) or atom."
  @spec parse(String.t() | atom()) :: {:ok, level()} | :error
  def parse(level) when is_map_key(@rank, level), do: {:ok, level}
  def parse(name) when is_map_key(@names, name), do: {:ok, Map.fetch!(@names, name)}
  def parse(_name), do: :error

  @doc "Like `parse/1`, raising for an unknown level."
  @spec parse!(String.t() | atom()) :: level()
  def parse!(name) do
    case parse(name) do
      {:ok, level} -> level
      :error -> raise ArgumentError, "unknown interruption level #{inspect(name)}"
    end
  end

  # CH-65 (3)
  @doc "The wire name of a level, which is also the iOS `interruption-level` value."
  @spec name(level()) :: String.t()
  def name(:time_sensitive), do: "time-sensitive"
  def name(level) when is_map_key(@rank, level), do: Atom.to_string(level)

  # CH-65 (3)
  @doc "The Web Push `Urgency` of a level, never above the class urgency of the table: Relay only lowers."
  @spec web_push_urgency(level() | nil, atom() | nil) :: atom() | nil
  def web_push_urgency(nil, _table), do: nil
  def web_push_urgency(_level, nil), do: nil

  def web_push_urgency(level, table) when is_map_key(@urgency_rank, table) do
    urgency = Map.fetch!(@urgency, level)
    if @urgency_rank[urgency] < @urgency_rank[table], do: urgency, else: table
  end

  # CH-65
  # CH-66
  # CH-67
  # CH-68
  # E-77
  @doc "Resolves the applied level of a notification and the reasons it records."
  @spec resolve(input()) :: result()
  def resolve(%{message_class: class, requested: requested, ceiling: ceiling} = input) do
    sensitive = Map.get(input, :sensitive, false) == true
    {level, reasons} = level(input, class, requested, ceiling)
    {level, reasons} = platform(level, reasons, Map.get(input, :platform_max, :critical))

    %{
      level: level,
      reasons: reasons,
      sensitive: sensitive,
      lock_screen: if(sensitive, do: :neutral, else: :content),
      content_free: sensitive
    }
  end

  defp level(_input, _class, nil, nil), do: {nil, []}
  defp level(_input, _class, _requested, nil), do: {nil, [:interruption_clamped]}

  defp level(input, class, requested, ceiling) do
    ceiling = ceiling(class, ceiling, Map.get(input, :personal_agent, false) == true)

    case requested do
      nil -> {lowest(input.default || ceiling, ceiling), []}
      :critical -> critical(input, ceiling)
      level -> clamp(level, ceiling)
    end
  end

  defp ceiling(:transactional, _ceiling, true), do: :time_sensitive
  defp ceiling(_class, ceiling, _personal_agent), do: ceiling

  defp clamp(level, ceiling) do
    if @rank[level] > @rank[ceiling], do: {ceiling, [:interruption_clamped]}, else: {level, []}
  end

  defp critical(input, ceiling) do
    opened =
      Map.get(input, :critical_enabled, false) == true and
        Map.get(input, :critical_declared, false) == true

    if opened and grant(Map.get(input, :grant, :unavailable)) == :permit,
      do: {:critical, []},
      else: {ceiling, [:critical_not_granted]}
  end

  defp grant(:permit), do: :permit

  defp grant(fun) when is_function(fun, 0) do
    case fun.() do
      :permit -> :permit
      _other -> :deny
    end
  rescue
    _exception -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp grant(_decision), do: :deny

  defp platform(nil, reasons, _max), do: {nil, reasons}

  defp platform(level, reasons, max) when is_map_key(@rank, max) do
    if @rank[level] > @rank[max],
      do: {max, reasons ++ [:interruption_platform_lowered]},
      else: {level, reasons}
  end

  defp lowest(level, ceiling), do: if(@rank[level] > @rank[ceiling], do: ceiling, else: level)
end
