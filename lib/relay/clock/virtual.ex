defmodule Relay.Clock.Virtual do
  @moduledoc """
  The virtual clock of the `test` plane. A tenant's `test` environment may move its business time forward by an offset that only grows; the offset lives in `relay.virtual_clocks`, whose rows can exist only for `test`. This module is the only reader of the offset and accepts no `live` scope, so a `live` call cannot reach it.
  """

  alias Relay.Clock.VirtualStore

  # TN-8
  # X-27
  @doc "Returns the scope's business time: the configured clock plus the tenant's virtual offset."
  @spec now(Relay.Scope.t()) :: DateTime.t()
  def now(%Relay.Scope{environment: :test} = scope),
    do: DateTime.add(Relay.Clock.utc_now(), offset_ms(scope), :millisecond)

  # T-24
  @doc "Converts a business time to the wall-clock time at which it falls due."
  @spec to_wall(Relay.Scope.t(), DateTime.t()) :: DateTime.t()
  def to_wall(%Relay.Scope{environment: :test} = scope, %DateTime{} = at),
    do: DateTime.add(at, -offset_ms(scope), :millisecond)

  # TN-8
  @doc "Returns the tenant's virtual offset in milliseconds; zero until the clock is first advanced. Inside a transaction of the same scope it reads in that transaction."
  @spec offset_ms(Relay.Scope.t()) :: non_neg_integer()
  def offset_ms(%Relay.Scope{environment: :test} = scope), do: VirtualStore.offset_ms(scope)
end
