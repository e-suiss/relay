defmodule Relay.Delivery.Send do
  @moduledoc """
  The job that sends one delivery. Its arguments carry the scope and identifiers only (T-15). The job, also when it starts at a delivery's `send_at`, first applies a cancellation tombstone written before the run started: a covered delivery becomes `cancelled` with the tombstone's rule (API-58, INV-6). It then reads the delivery's gate: a delivery that is cancelled, paused, terminal or gone ends the job without error.

  Every other run passes the policy lattice again (PC-8), through the lattice step configured as `config :relay, Relay.Delivery, lattice: Module`, by default `Relay.Policy.Live`, whose `job/2` it calls; the delivery context itself depends on no other context (T-56): a skip, an expiry or a kill switch pause is recorded and ends the job; a deferral is recorded and the job runs again at `deferred_until`, which carries the release jitter; a delivery the lattice holds in a digest window ends the job, and the window queues it again when it fires (PC-46, WF-30); an input that cannot be read records nothing and the job retries (INV-43), and while the kill switch state is unknown it waits five seconds (TN-38). A delivery the lattice sends is rendered from its pinned plan through the renderer step configured as `config :relay, Relay.Delivery, renderer: Module`, by default `Relay.Templates.Live`, whose `render/2` it calls (TP-50): a render failure is recorded with its `failure_reason` and ends the job without retry (TP-41, INV-46), and a render input that cannot be read records nothing and the job retries. A rendered delivery passes the content deduplication step configured as `config :relay, Relay.Delivery, content_dedup: Module`, by default `Relay.Workflow`, whose `content_dedup/2` it calls (WF-35): a repeat of the same content to the same recipient and channel inside the window is recorded as skipped and ends the job, and a check that cannot be read records nothing and the job retries. A delivery that is not a repeat is handed to its provider through the channel step configured as `config :relay, Relay.Delivery, channel: Module`, by default `Relay.Channels.Live`, whose `deliver/3` it calls with the job's arguments (CH-2): the step routes, calls the adapter and records the attempt; a retry is a new job (T-26). With `channel: nil` a rendered delivery waits in the queue and the job comes back later. When a job run ends, the settled step configured as `config :relay, Relay.Delivery, settled: Module`, by default `Relay.Workflow`, whose `delivery_settled/2` it calls, lets the workflow run of the delivery evaluate its route again (WF-15); `settled: nil` turns it off.
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 30_000

  alias Relay.Scope

  @wait_s 300
  @channel Relay.Channels.Live
  @hold_s 5

  # T-15
  # TN-40
  # API-58
  # INV-6
  # PC-8
  # INV-43
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, delivery_id} <- Relay.Id.parse(delivery),
         {:ok, {_tombstone, _cancellation}} <- Relay.Delivery.apply_tombstone(scope, delivery_id),
         {:ok, %{result: result}} <- Relay.Delivery.gate(scope, delivery_id) do
      outcome =
        if result in [:sendable, :deferred, :expired],
          do: decide(scope, delivery_id, args),
          else: :ok

      settled(outcome, scope, delivery_id)
    end
  end

  # WF-15
  defp settled(:held, _scope, _delivery_id), do: :ok

  defp settled(:ok, scope, delivery_id) do
    case settled_step() do
      nil -> :ok
      module -> module.delivery_settled(scope, delivery_id)
    end
  end

  defp settled(outcome, _scope, _delivery_id), do: outcome

  # PC-58 (5)
  # WF-42
  defp decide(scope, delivery_id, args) do
    case lattice().job(scope, delivery_id) do
      {:send, _info} -> render(scope, delivery_id, args)
      {:defer, until} -> {:snooze, seconds_until(Relay.Clock.wall_time(scope, until))}
      :held -> :held
      :done -> :ok
      {:error, {:input_unavailable, :kill_switch}} -> {:snooze, @hold_s}
      {:error, reason} -> {:error, reason}
    end
  end

  # TP-41
  # TP-50
  # INV-46
  defp render(scope, delivery_id, args) do
    case renderer().render(scope, delivery_id) do
      :rendered -> content(scope, delivery_id, args)
      {:error, reason} -> {:error, reason}
      _failed_or_done -> :ok
    end
  end

  # WF-35
  # WF-36
  defp content(scope, delivery_id, args) do
    case content_dedup().content_dedup(scope, delivery_id) do
      :send -> channel(scope, delivery_id, args)
      :skipped -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # CH-2
  # T-26
  defp channel(scope, delivery_id, args) do
    step = :relay |> Application.get_env(Relay.Delivery, []) |> Keyword.get(:channel, @channel)

    case step do
      nil -> {:snooze, @wait_s}
      module -> module.deliver(scope, delivery_id, args)
    end
  end

  defp renderer do
    :relay
    |> Application.get_env(Relay.Delivery, [])
    |> Keyword.get(:renderer, Relay.Templates.Live)
  end

  defp content_dedup do
    :relay
    |> Application.get_env(Relay.Delivery, [])
    |> Keyword.get(:content_dedup, Relay.Workflow)
  end

  defp settled_step do
    :relay
    |> Application.get_env(Relay.Delivery, [])
    |> Keyword.get(:settled, Relay.Workflow)
  end

  defp lattice do
    :relay |> Application.get_env(Relay.Delivery, []) |> Keyword.get(:lattice, Relay.Policy.Live)
  end

  defp seconds_until(at) do
    ms = DateTime.diff(at, Relay.Clock.utc_now(), :millisecond)
    max(div(ms + 999, 1000), 1)
  end
end
