defmodule Relay.Api.Campaigns.SendSource do
  @moduledoc """
  The fan-out source of a campaign stage (`source_kind` `campaign`, T-23): a page is the stage's members in identifier order inside the slice's range, and a sub-batch queues one `Relay.Api.Campaigns.SendJob` for its first and last member on the campaign's lane, in the sub-batch's transaction. A sub-batch of a campaign that is no longer running or paused queues nothing.
  """

  alias Relay.Api.Campaigns
  alias Relay.Api.Campaigns.SendJob
  alias Relay.Api.Campaigns.Store

  @classes Map.new(
             ~w(transactional operational social marketing system action_required)a,
             &{Atom.to_string(&1), &1}
           )

  # T-23 (1)
  @doc "At most `limit` member identifiers of the fan-out's stage from `position` and below `range_to`."
  @spec page(Relay.Scope.t(), map(), Store.position(), Relay.Id.t() | nil, pos_integer()) ::
          [Relay.Id.t()]
  def page(_scope, fanout, position, range_to, limit),
    do: Store.stage_page(fanout.source_id, position, range_to, limit)

  # T-23
  # WF-44
  @doc "Queues the send job of one sub-batch and counts its members processed."
  @spec process(Relay.Scope.t(), map(), [Relay.Id.t(), ...]) ::
          {non_neg_integer(), non_neg_integer()}
  def process(scope, fanout, ids) do
    with %{"campaign_id" => campaign_id} <- Store.stage(fanout.source_id),
         %{"state" => state} = c when state in ["running", "paused"] <- Store.get(campaign_id) do
      :ok = enqueue(scope, c, List.first(ids), List.last(ids), length(ids))
    end

    {length(ids), 0}
  end

  defp enqueue(scope, c, from, to, count) do
    args =
      scope
      |> Campaigns.job_args(c["id"])
      |> Map.merge(%{"from" => Relay.Id.to_string(from), "to" => Relay.Id.to_string(to)})

    job = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(Map.fetch!(@classes, c["message_class"])),
      worker: SendJob,
      args: args,
      ref_kind: "campaign_batch",
      ref_id: c["id"],
      priority: Relay.Platform.job_priority(:next_slice, 1, :normal),
      cost: count
    }

    case Relay.Platform.enqueue_job(job) do
      {:ok, _queued} -> :ok
      {:error, reason} -> Store.rollback({:not_queued, reason})
    end
  end
end
