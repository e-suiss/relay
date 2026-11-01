defmodule Relay.Policy.Priority do
  @moduledoc """
  The priority ceiling of a message class (PC-58 (7), API-22): `security`, `action_required` and `transactional` may ask for `high`; `operational`, `social` and `marketing` for at most `normal`; `system` for `low`. A requested priority above the ceiling is lowered to it and the delivery records the lowered value; no priority is `normal` under the ceiling.
  """

  alias Relay.Policy.Snapshot

  @rank %{low: 0, normal: 1, high: 2}
  @ceilings %{
    security: :high,
    action_required: :high,
    transactional: :high,
    operational: :normal,
    social: :normal,
    marketing: :normal,
    system: :low
  }

  # PC-58 (7)
  # API-22
  @doc "The ceiling of a class."
  @spec ceiling(Snapshot.message_class()) :: Snapshot.priority()
  def ceiling(class), do: Map.fetch!(@ceilings, class)

  # PC-58 (7)
  # API-22
  # INV-16
  @doc "Clamps a requested priority to the class ceiling; returns the priority and whether a requested value was lowered."
  @spec clamp(Snapshot.message_class(), Snapshot.priority() | nil) ::
          {Snapshot.priority(), boolean()}
  def clamp(class, nil), do: {lower(:normal, ceiling(class)), false}

  def clamp(class, requested) when is_map_key(@rank, requested) do
    ceiling = ceiling(class)
    clamped = lower(requested, ceiling)
    {clamped, clamped != requested}
  end

  defp lower(priority, ceiling),
    do: if(@rank[priority] > @rank[ceiling], do: ceiling, else: priority)
end
