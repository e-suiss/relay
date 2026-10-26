defmodule Relay.Tenancy.KillSwitch.Snapshot do
  @moduledoc """
  The full set of active kill switch records as one immutable value, indexed by scope so that a message looks up only the records of its own scopes (TN-39). A platform record applies to every tenant and both environments; every other record only to its own tenant and environment (TN-7, S-47).
  """

  alias Relay.Tenancy.KillSwitch.Record

  @enforce_keys [:generation, :index]
  defstruct [:generation, :index, count: 0]

  @type key ::
          :platform
          | {:tenant, Relay.Id.t(), Relay.Environment.t()}
          | {Record.scope_kind(), Relay.Id.t(), Relay.Environment.t(), String.t()}
  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          index: %{key() => [Record.t()]},
          count: non_neg_integer()
        }

  @doc "Builds a snapshot of `generation` from records; released records are left out."
  @spec new(non_neg_integer(), [Record.t()]) :: t()
  def new(generation, records) when is_integer(generation) and generation >= 0 do
    active = Enum.filter(records, &(&1.status == :active))

    %__MODULE__{
      generation: generation,
      index: Enum.group_by(active, &key/1),
      count: length(active)
    }
  end

  defp key(%Record{scope_kind: :platform}), do: :platform
  defp key(%Record{scope_kind: :tenant} = r), do: {:tenant, r.tenant_id, r.environment}
  defp key(%Record{} = r), do: {r.scope_kind, r.tenant_id, r.environment, r.scope_ref}

  @doc "Returns the records whose scope can match a message of `tenant_id` and `environment` with the given scope references (`nil` references match nothing)."
  @spec candidates(t(), Relay.Id.t(), Relay.Environment.t(), [
          {Record.scope_kind(), String.t() | nil}
        ]) :: [Record.t()]
  def candidates(%__MODULE__{index: index}, tenant_id, environment, refs) do
    keys =
      [:platform, {:tenant, tenant_id, environment}] ++
        for {kind, ref} <- refs, is_binary(ref), do: {kind, tenant_id, environment, ref}

    Enum.flat_map(keys, &Map.get(index, &1, []))
  end
end
