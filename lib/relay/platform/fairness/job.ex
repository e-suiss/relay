defmodule Relay.Platform.Fairness.Job do
  @moduledoc """
  A job on its way into a lane. `:id` is a fresh UUIDv7 and is the job's wait table key in the bulk lanes; `:args` carry identifiers only (at most 1 KiB as JSON); `:cost` is the number of deliveries the job opens, at most the DRR quantum; `:ref_kind` and `:ref_id` name what cancelling the record behind the job cancels (`delivery`, `notification`, `fanout`, `fanout_slice` …). `:priority` comes from `Relay.Platform.Lane.priority/3`. A job without `:scheduled_at` is due at once.
  """

  @enforce_keys [:id, :lane, :worker, :args, :ref_kind, :ref_id]
  defstruct [
    :id,
    :lane,
    :worker,
    :args,
    :ref_kind,
    :ref_id,
    :scheduled_at,
    priority: 1,
    cost: 1
  ]

  @type t :: %__MODULE__{
          id: Relay.Id.t(),
          lane: Relay.Platform.Lane.t(),
          worker: module(),
          args: map(),
          ref_kind: String.t(),
          ref_id: Relay.Id.t(),
          scheduled_at: DateTime.t() | nil,
          priority: 0..9,
          cost: pos_integer()
        }

  @doc "The worker module's name as Oban stores it."
  @spec worker_name(t()) :: String.t()
  def worker_name(%__MODULE__{worker: worker}) when is_atom(worker),
    do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
