defmodule Relay.Platform.Lane do
  @moduledoc """
  The four lanes and the job queue topology. A lane follows only from the message class: `security` runs on `l0`, `transactional` and `action_required` on `l1`, `operational`, `system` and `social` on `l2`, `marketing` on `l3`. No request field, priority, tenant or channel takes part, so nothing can move a message to another lane.

  Every lane has its own Oban queue and its own per-node concurrency budget; replays of dead letters and maintenance jobs run in their own queues. Channel queues (`<lane>_<channel>`, for example `l0_sms`) join the topology when the channel adapters arrive. Queue names and budgets live here, in code, and the Oban configuration of a worker node is built from `queues/0`.

  The bulk lanes `l2` and `l3` pass through the tenant wait table and the DRR dispatcher before they reach their queue; `l0` and `l1` jobs are inserted into their queue directly. The critical lanes (`l0`, `l1`) write through the OLTP pool `Relay.Repo`, the bulk lanes through `Relay.BulkRepo`.

  The priority inside a lane (0 is served first) is set by `priority/3`.
  """

  @type t :: :l0 | :l1 | :l2 | :l3
  @type message_class ::
          :security
          | :transactional
          | :action_required
          | :operational
          | :system
          | :social
          | :marketing
  @type channel ::
          :push
          | :web_push
          | :email
          | :sms
          | :voice
          | :whatsapp
          | :slack
          | :teams
          | :telegram
          | :discord
          | :in_app
          | :webhook
  @type queue :: atom()
  @type pool :: :oltp | :bulk
  @type requested_priority :: :high | :normal | :low
  @type job_kind ::
          :delivery
          | :scheduled
          | :waitpoint_timer
          | :digest
          | :first_slice
          | :next_slice
          | :dlq_replay
          | :maintenance

  @lanes [:l0, :l1, :l2, :l3]
  @channels [
    :push,
    :web_push,
    :email,
    :sms,
    :voice,
    :whatsapp,
    :slack,
    :teams,
    :telegram,
    :discord,
    :in_app,
    :webhook
  ]
  @queues [l0: 20, l1: 20, l2: 10, l3: 5, dlq_replay: 2, maintenance: 2]
  @queue_name ~r/^l[0-3](_[a-z_]+)?$/
  @lane_names %{"l0" => :l0, "l1" => :l1, "l2" => :l2, "l3" => :l3}

  # T-31
  # INV-16
  # INV-24
  @doc "The lane of a message class. It takes nothing but the class."
  @spec of(message_class()) :: t()
  def of(:security), do: :l0
  def of(:transactional), do: :l1
  def of(:action_required), do: :l1
  def of(:operational), do: :l2
  def of(:system), do: :l2
  def of(:social), do: :l2
  def of(:marketing), do: :l3

  @doc "The four lanes, most urgent first."
  @spec all() :: [t(), ...]
  def all, do: @lanes

  @doc "The channels a channel queue may name (`relay.channel`)."
  @spec channels() :: [channel(), ...]
  def channels, do: @channels

  # T-21 (2)
  # T-21 (4)
  # T-91 (2)
  @doc "True for the lanes whose jobs wait in the tenant wait table for the DRR dispatcher: `l2` and `l3`."
  @spec fair?(t()) :: boolean()
  def fair?(lane) when lane in [:l2, :l3], do: true
  def fair?(lane) when lane in [:l0, :l1], do: false

  # T-32 (3)
  @doc "The database pool a lane writes through: `:oltp` for `l0` and `l1`, `:bulk` for `l2` and `l3`."
  @spec pool(t()) :: pool()
  def pool(lane) when lane in [:l0, :l1], do: :oltp
  def pool(lane) when lane in [:l2, :l3], do: :bulk

  # T-90
  # T-91 (1)
  # T-32 (1)
  # TN-51
  @doc "The Oban queues of a worker node with their per-node concurrency; the Oban `queues:` option is this list."
  @spec queues() :: [{queue(), pos_integer()}, ...]
  def queues, do: @queues

  @doc "Per-node concurrency budget of a configured queue."
  @spec budget(queue()) :: pos_integer()
  def budget(queue) when is_atom(queue), do: Keyword.fetch!(@queues, queue)

  # T-90
  @doc "The queue of a lane."
  @spec queue(t()) :: queue()
  def queue(lane) when lane in @lanes, do: lane

  # T-90
  @doc "The lane a queue name belongs to (`l<k>` or `l<k>_<channel>`), or nil for the other queues."
  @spec lane_of_queue(String.t() | atom()) :: t() | nil
  def lane_of_queue(queue) when is_atom(queue), do: lane_of_queue(Atom.to_string(queue))

  def lane_of_queue(queue) when is_binary(queue) do
    with true <- Regex.match?(@queue_name, queue),
         true <- channel_part?(binary_part(queue, 2, byte_size(queue) - 2)) do
      Map.fetch!(@lane_names, binary_part(queue, 0, 2))
    else
      false -> nil
    end
  end

  @doc "The configured queues of a lane, as queue name strings."
  @spec lane_queues(t()) :: [String.t(), ...]
  def lane_queues(lane) when lane in @lanes do
    for {queue, _budget} <- @queues, lane_of_queue(queue) == lane, do: Atom.to_string(queue)
  end

  defp channel_part?(""), do: true

  defp channel_part?("_" <> channel),
    do: Enum.any?(@channels, &(Atom.to_string(&1) == channel))

  defp channel_part?(_other), do: false

  # T-36
  @doc """
  Priority of a job inside its queue, 0 first.

  | Priority | Job |
  |---|---|
  | 0 | first attempt of a delivery requested `high` (already capped to the class ceiling); a dead-letter replay or maintenance job in its own queue |
  | 1 | first attempt requested `normal` or `low` |
  | 2 | second and third attempt |
  | 3 | a scheduled job that came due; a waitpoint timer |
  | 4 | a digest firing |
  | 5 | the first slice of a campaign or fan-out |
  | 6 | a later slice |
  | 7 | a retried bulk slice |
  | 8 | fourth and later attempt |

  Priority 9 is not used. `attempt_no` counts from 1.
  """
  @spec priority(job_kind(), pos_integer(), requested_priority()) :: 0..8
  def priority(kind, attempt_no, requested)
      when is_integer(attempt_no) and attempt_no >= 1 and requested in [:high, :normal, :low],
      do: do_priority(kind, attempt_no, requested)

  defp do_priority(:delivery, 1, :high), do: 0
  defp do_priority(:delivery, 1, _requested), do: 1
  defp do_priority(:delivery, attempt_no, _requested) when attempt_no <= 3, do: 2
  defp do_priority(:delivery, _attempt_no, _requested), do: 8
  defp do_priority(:scheduled, _attempt_no, _requested), do: 3
  defp do_priority(:waitpoint_timer, _attempt_no, _requested), do: 3
  defp do_priority(:digest, _attempt_no, _requested), do: 4
  defp do_priority(:first_slice, 1, _requested), do: 5
  defp do_priority(:next_slice, 1, _requested), do: 6

  defp do_priority(slice, _attempt_no, _requested) when slice in [:first_slice, :next_slice],
    do: 7

  defp do_priority(:dlq_replay, _attempt_no, _requested), do: 0
  defp do_priority(:maintenance, _attempt_no, _requested), do: 0
end
