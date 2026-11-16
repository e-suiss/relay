defmodule Relay.Policy.Live.Hold do
  @moduledoc """
  Holds a delivery the lattice decided in a digest window of the policy lattice instead of letting it go alone (`Relay.Workflow.Digest`), inside the caller's transaction, where the decision is recorded:

  * the morning burst guard (PC-46): a `social` or `marketing` delivery that quiet hours defer joins the window of the recipient's category and channel released at the deferral's jittered end;
  * the `digest` fate of the frequency cap (PC-50, PC-58 (6)): a capped delivery joins the window of the recipient's category and channel released when a slot frees;
  * the density threshold (WF-30): a delivery the lattice sends in a category with a threshold is counted per recipient (or, with `per: device`, per recipient and device channel for `push` and `web_push`), and past the threshold it joins the window of its category and channel, a fixed window as long as the threshold's.

  A held delivery is recorded as deferred with its digest rule (`digest.quiet_hours`, `frequency.digest`, `digest.density`) until the window fires, and no job waits for it: the window's release (`release/2`) queues the job of the first held delivery, which goes with the digest render data when the window holds two or more, records the others skipped with `digest.folded`, and queues every held delivery again when the window is cancelled. A delivery a fired window already released is not held again by the same window key, so it passes the lattice like any other.
  """

  alias Relay.Policy.Live.Store
  alias Relay.Scope

  @quiet_classes [:social, :marketing]
  @density_classes [:social, :marketing, :operational]
  @device_channels [:push, :web_push]
  @folded "digest.folded"

  @type input :: %{
          delivery_id: Relay.Id.t(),
          notification_id: Relay.Id.t(),
          recipient_id: Relay.Id.t(),
          channel: atom(),
          category: map()
        }

  # PC-46
  # PC-50
  # PC-58 (6)
  # WF-30
  @doc "The decision to record for a lattice result: `{:held, deferral}` when the delivery waits in a digest window, otherwise `:none` and the result stands."
  @spec hold(Scope.t(), input(), term()) :: {:held, tuple()} | :none
  def hold(scope, %{category: %{message_class: class}} = input, result) do
    cond do
      match?({:defer, _, "quiet_hours.deferred", _, _}, result) and class in @quiet_classes ->
        quiet(scope, input, elem(result, 3))

      match?({:defer, _, "frequency.digest", _, _}, result) ->
        frequency(scope, input, elem(result, 3), elem(result, 4))

      match?({:send, _}, result) and class in @density_classes ->
        density(scope, input, Map.get(input.category, :density))

      true ->
        :none
    end
  end

  def hold(_scope, _input, _result), do: :none

  # PC-46
  # WF-42
  defp quiet(scope, input, until) do
    attrs = Map.put(window_attrs(input), :release_at, until)

    detail = %{
      category: input.category.key,
      channel: Atom.to_string(input.channel),
      release_at: until
    }

    held(Relay.Workflow.digest_quiet_hours(scope, attrs), "digest.quiet_hours", detail)
  end

  # PC-50
  # PC-58 (6)
  defp frequency(scope, input, until, detail) do
    attrs = Map.put(window_attrs(input), :release_at, until)
    detail = Map.put(detail, :category, input.category.key)
    held(Relay.Workflow.digest_frequency(scope, attrs), "frequency.digest", detail)
  end

  # WF-30
  defp density(_scope, _input, nil), do: :none

  defp density(scope, input, %{"limit" => limit, "window" => window} = threshold) do
    attrs =
      input
      |> window_attrs()
      |> Map.merge(%{
        threshold: %{"limit" => limit, "window" => window},
        ref: Relay.Id.to_string(input.delivery_id),
        device: device(threshold["per"], input.channel),
        step: %{"mode" => "fixed", "max_wait" => window}
      })

    detail = %{category: input.category.key, limit: limit, window: window}

    case Relay.Workflow.digest_density(scope, attrs) do
      {:ok, :under} -> :none
      added -> held(added, "digest.density", detail)
    end
  end

  defp device("device", channel) when channel in @device_channels, do: Atom.to_string(channel)
  defp device(_per, _channel), do: nil

  defp window_attrs(input) do
    %{
      recipient_id: input.recipient_id,
      notification_id: input.notification_id,
      delivery_id: input.delivery_id,
      message_class: Atom.to_string(input.category.message_class),
      category: input.category.key,
      channel: Atom.to_string(input.channel)
    }
  end

  defp held({:ok, %{held: true, fire_at: %DateTime{} = at, window_id: id}}, rule, detail) do
    detail = Map.put(detail, :window_id, Relay.Id.to_string(id))
    {:held, {:defer, :digested, rule, at, detail}}
  end

  defp held(_not_held, _rule, _detail), do: :none

  # PC-46
  # PC-50
  # WF-30
  # WF-27
  @doc "Releases what a fired or cancelled window of the policy lattice held, inside the window's closing transaction (the `release` of `Relay.Workflow.Digest`): the first delivery's job is queued, and with a digest the others are recorded skipped with `digest.folded`; a single item or a cancelled window queues every held delivery's job."
  @spec release(Scope.t(), {atom(), map()}) :: :ok
  def release(%Scope{} = scope, {:digest, %{deliveries: [first | rest]} = info}) do
    :ok = queue(scope, first)
    window = Relay.Id.to_string(info.window_id)
    detail = %{window_id: window, digest_of: Relay.Id.to_string(first)}

    Enum.each(rest, fn id ->
      _ = Store.decide(id, "skip", "digested", @folded, nil, detail)
    end)
  end

  def release(%Scope{} = scope, {_single_or_cancelled, %{deliveries: ids}}),
    do: Enum.each(ids, &(:ok = queue(scope, &1)))

  def release(_scope, _outcome), do: :ok

  defp queue(scope, delivery_id),
    do: Relay.Workflow.queue_job!(Relay.Delivery.send_job(scope, delivery_id))
end
