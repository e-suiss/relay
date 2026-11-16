defmodule Relay.Timing.Store do
  @moduledoc """
  Database reads of the tenant's jitter control (`Relay.Timing`), inside the caller's scoped transaction.
  """

  # WF-58
  @doc "The stored value of a tenant-level setting key, or `nil` when it is not set."
  @spec setting(String.t()) :: term()
  def setting(key) when is_binary(key) do
    case Relay.Repo.call!("relay_fn.setting_resolve", [nil, [key]]) do
      [%{"value" => value} | _rest] -> value
      [] -> nil
    end
  end
end
