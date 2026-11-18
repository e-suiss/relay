defmodule Relay.Migration.Routing do
  @moduledoc """
  Where a staged rollout sends a request (OP-53, OP-95), in a fixed order: the emergency stop sends everything to the system being replaced; a recipient on the pinned Relay list goes to Relay and one on the pinned legacy list to the legacy system; a category that is not enabled goes to the legacy system; otherwise the recipient's bucket below the category's basis points goes to Relay and every other request to the legacy system. Without a configuration every request goes to Relay. The split unit is always the recipient, never a random draw.
  """

  alias Relay.Migration.Bucket

  @type config :: %{
          required(:emergency_stop) => boolean(),
          required(:relay_list) => MapSet.t(binary()),
          required(:legacy_list) => MapSet.t(binary()),
          required(:enabled_categories) => MapSet.t(String.t()),
          required(:basis_points) => %{String.t() => non_neg_integer()}
        }

  # OP-53
  # OP-95
  @doc "Routes the request of a recipient of a category to `:relay` or `:legacy`."
  @spec route(config() | nil, Relay.Id.t(), String.t() | nil, String.t()) :: :relay | :legacy
  def route(nil, _tenant_id, _category, _external_id), do: :relay
  def route(%{emergency_stop: true}, _tenant_id, _category, _external_id), do: :legacy

  def route(config, tenant_id, category, external_id) do
    digest = Bucket.digest(tenant_id, external_id)

    cond do
      MapSet.member?(config.relay_list, digest) -> :relay
      MapSet.member?(config.legacy_list, digest) -> :legacy
      not MapSet.member?(config.enabled_categories, category) -> :legacy
      Bucket.bucket(tenant_id, external_id) < Map.get(config.basis_points, category, 0) -> :relay
      true -> :legacy
    end
  end
end
