defmodule Relay.Migration.Ramp do
  @moduledoc """
  The ramp rule of a staged rollout (OP-53, OP-95): lowering a category's share is always allowed and is the rollback; raising it takes at most five times the previous share, at most the floor of 100 basis points (1 percent) when the previous share is below it, and at least one full day since the category's last change. A category left out of a configuration has share 0. Each change of a category records its share and the time of the change, which the next raise is measured from.
  """

  @factor Relay.Limits.fetch!(["rollout", "ramp_factor"])
  @floor Relay.Limits.fetch!(["rollout", "ramp_floor_basis_points"])
  @interval_s Relay.Limits.seconds!(["rollout", "ramp_min_interval"])

  @type steps :: %{String.t() => %{String.t() => term()}}

  # OP-53
  # OP-95
  @doc "Checks the shares `next` against the recorded `steps` at `now`; returns the steps to record or the field errors of the shares that break the rule."
  @spec check(steps(), %{String.t() => non_neg_integer()}, DateTime.t()) ::
          {:ok, steps()} | {:error, [map()]}
  def check(steps, next, %DateTime{} = now) when is_map(steps) and is_map(next) do
    categories = Enum.uniq(Map.keys(steps) ++ Map.keys(next))

    {kept, errors} =
      Enum.reduce(Enum.sort(categories), {%{}, []}, fn category, {kept, errors} ->
        previous = share(steps[category])
        wanted = Map.get(next, category, 0)

        case step(previous, wanted, changed_at(steps[category]), now) do
          :same -> {Map.put(kept, category, steps[category]), errors}
          :ok -> {Map.put(kept, category, entry(wanted, now)), errors}
          {:error, detail} -> {kept, [error(category, detail) | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Map.reject(kept, fn {_category, entry} -> is_nil(entry) end)}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # OP-53
  @doc "The largest share a raise from `previous` may reach."
  @spec ceiling(non_neg_integer()) :: number()
  def ceiling(previous), do: min(max(previous * @factor, @floor), 10_000)

  defp step(previous, previous, _at, _now), do: :same
  defp step(previous, wanted, _at, _now) when wanted < previous, do: :ok

  defp step(previous, wanted, at, now) do
    cond do
      wanted > ceiling(previous) ->
        {:error, "a raise reaches at most #{ceiling(previous)} basis points"}

      at != nil and DateTime.diff(now, at) < @interval_s ->
        {:error, "a raise needs one day since the last change"}

      true ->
        :ok
    end
  end

  defp share(%{"basis_points" => bp}) when is_integer(bp), do: bp
  defp share(_entry), do: 0

  defp changed_at(%{"changed_at" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp changed_at(_entry), do: nil

  defp entry(bp, now) do
    %{
      "basis_points" => bp,
      "changed_at" => DateTime.to_iso8601(%{now | microsecond: {0, 0}})
    }
  end

  defp error(category, detail),
    do: %{pointer: "/basis_points/" <> category, code: "not_allowed", detail: detail}
end
