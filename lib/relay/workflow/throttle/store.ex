defmodule Relay.Workflow.Throttle.Store do
  @moduledoc """
  Data access of throttle counters through `relay_fn.throttle_hit` and `relay_fn.throttle_reset`. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # WF-32
  # WF-33
  @doc "Counts one event against the active counter of a key, opening the window `bounds` describes when none is active; a repeated event answers its first outcome."
  @spec hit(<<_::256>>, <<_::256>>, pos_integer(), term()) :: map()
  def hit(key_digest, hit_key, limit, bounds) do
    {window_ms, window_start, window_end} = params(bounds)

    [row] =
      Repo.call!("relay_fn.throttle_hit", [
        key_digest,
        hit_key,
        limit,
        window_ms,
        window_start,
        window_end
      ])

    %{
      outcome: Repo.code!(row["result"], [:allowed, :limited]),
      counter_id: row["counter_id"],
      count: row["hit_count"],
      window_end: row["window_end"],
      repeated: row["repeated"]
    }
  end

  # WF-32
  # API-69
  @doc "Resets the active counter of a key, audited with the caller's record digest."
  @spec reset(<<_::256>>, <<_::256>>, Actor.t()) :: {:reset | :not_active, Relay.Id.t() | nil}
  def reset(key_digest, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.throttle_reset", [key_digest, digest | Actor.params(actor)])
    {Repo.code!(row["result"], [:reset, :not_active]), row["counter_id"]}
  end

  defp params({:anchored, ms}), do: {ms, nil, nil}
  defp params({:until, until}), do: {nil, nil, until}
  defp params({:span, start, stop}), do: {nil, start, stop}
end
