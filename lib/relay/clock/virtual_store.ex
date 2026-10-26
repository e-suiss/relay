defmodule Relay.Clock.VirtualStore do
  @moduledoc false

  alias Relay.Repo

  @spec offset_ms(Relay.Scope.t()) :: non_neg_integer()
  def offset_ms(%Relay.Scope{environment: :test} = scope) do
    if Repo.current_scope() == scope do
      read()
    else
      {:ok, offset} = Repo.in_scope(scope, fn _status -> read() end)
      offset
    end
  end

  defp read do
    [%{"result" => "ok", "offset_ms" => offset}] = Repo.call!("relay_fn.virtual_clock_get", [])
    offset
  end
end
