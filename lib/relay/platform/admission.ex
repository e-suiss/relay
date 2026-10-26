defmodule Relay.Platform.Admission do
  @moduledoc """
  Admission control at the entrance, as a pure function: the cheapest place to shed work is before it exists. Overload answers `503` with `Retry-After`, never `429`, which stays for tenant quota and rate limits. A `security` message is never refused, and an `l1` message is admitted while its lane sheds, to be postponed in the queue rather than lost.

  | # | Condition, in order | Result | Rule |
  |---|---|---|---|
  | 1 | class `security` | admit | — |
  | 2 | lane `l1` while `l1` sheds | admit | — |
  | 3 | lane `l2` while `l2` sheds | 503, retry after 60 s | `admission.overload.l2` |
  | 4 | lane `l3` while `l3` sheds | 503, retry after 1 800 s | `admission.overload.l3` |
  | 5 | `marketing` and every requested channel has all its providers' breakers open | 503, retry after the shortest remaining open time, at least 1 s | `admission.breaker_open` |
  | 6 | lane `l2` or `l3` with a known capacity and `queued + 1 > μ · W_max` | 503, retry after `ceil(W_max)` seconds | `admission.lmax.<lane>` |
  | 7 | otherwise | admit | — |

  `breaker_open` names the channels whose providers are all open; the optional `breaker_remaining_ms` gives each one's remaining open time. `lane_capacity` gives a lane's service rate per second, its target wait in milliseconds and its queued jobs; a lane without it is not checked against `L_max`. A database pool that cannot hand out a connection is an infrastructure failure, not an admission decision: the request fails with `503` and nothing is recorded, `security` included.
  """

  alias Relay.Platform.Lane

  @type capacity :: {mu_per_s :: number(), w_max_ms :: pos_integer(), queued :: non_neg_integer()}
  @type input :: %{
          required(:message_class) => Lane.message_class(),
          required(:channels) => [Lane.channel()],
          required(:shed) => %{l1: boolean(), l2: boolean(), l3: boolean()},
          required(:breaker_open) => MapSet.t(Lane.channel()),
          optional(:breaker_remaining_ms) => %{Lane.channel() => non_neg_integer()},
          required(:lane_capacity) => %{optional(Lane.t()) => capacity() | nil} | nil
        }
  @type rejection :: %{status: 503, retry_after_s: pos_integer(), rule_id: String.t()}

  # API-51
  # T-35
  # T-92
  # INV-24
  @doc "Admits or refuses a request; see the table in the module documentation."
  @spec decide(input()) :: :admit | {:reject, rejection()}
  def decide(%{message_class: :security}), do: :admit

  def decide(%{message_class: class} = input), do: decide(Lane.of(class), class, input)

  defp decide(:l1, _class, _input), do: :admit
  defp decide(:l2, _class, %{shed: %{l2: true}}), do: reject(60, "admission.overload.l2")
  defp decide(:l3, _class, %{shed: %{l3: true}}), do: reject(1_800, "admission.overload.l3")

  defp decide(lane, class, input) do
    cond do
      class == :marketing and breakers_open?(input) ->
        reject(breaker_retry_after(input), "admission.breaker_open")

      over_lmax?(lane, input) ->
        {_mu, w_max_ms, _queued} = capacity(lane, input)
        reject(max(div(w_max_ms + 999, 1_000), 1), "admission.lmax.#{lane}")

      true ->
        :admit
    end
  end

  defp reject(retry_after_s, rule_id),
    do: {:reject, %{status: 503, retry_after_s: retry_after_s, rule_id: rule_id}}

  defp breakers_open?(%{channels: [_ | _] = channels, breaker_open: open}),
    do: Enum.all?(channels, &MapSet.member?(open, &1))

  defp breakers_open?(_input), do: false

  defp breaker_retry_after(%{channels: channels} = input) do
    remaining = Map.get(input, :breaker_remaining_ms) || %{}

    channels
    |> Enum.map(&Map.get(remaining, &1, 0))
    |> Enum.min()
    |> Kernel.+(999)
    |> div(1_000)
    |> max(1)
  end

  defp over_lmax?(lane, input) do
    case capacity(lane, input) do
      {mu, w_max_ms, queued} when is_number(mu) and is_integer(w_max_ms) and is_integer(queued) ->
        (queued + 1) * 1_000 > mu * w_max_ms

      _unknown ->
        false
    end
  end

  defp capacity(lane, %{lane_capacity: %{} = capacity}), do: Map.get(capacity, lane)
  defp capacity(_lane, _input), do: nil
end
