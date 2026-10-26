defmodule Relay.Delivery.DeadLetters.AutoReplay do
  @moduledoc """
  The automatic replay after a provider's circuit breaker closes (T-29 (6)): the provider's open `exhausted` dead letters of the last 30 minutes are replayed by the system actor, tenant by tenant. The tenants are found through the maintenance escape hatch by identifiers only; each candidate is read and replayed under its own tenant's scope.

  The replay job is built by the configured send worker (`config :relay, Relay.Delivery, send_worker: Module`) in the `dlq_replay` queue; without one nothing is replayed.
  """

  use Relay.Worker,
    queue: :maintenance,
    max_attempts: 3,
    timeout: 300_000

  require Logger

  @handler "relay-dead-letter-auto-replay"
  @limit 1000

  # T-29 (6)
  @doc "Attaches the telemetry handler that queues this job when a provider-level breaker closes."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach,
    do:
      :telemetry.attach(
        @handler,
        [:relay, :breaker, :transition],
        &__MODULE__.handle_event/4,
        nil
      )

  # T-29 (6)
  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(_event, _measurements, %{level: :provider, to: :closed, provider: provider}, _)
      when is_binary(provider) do
    metadata = Logger.metadata()

    if is_nil(metadata[:correlation_id]),
      do:
        Logger.metadata(
          correlation_id: "cor_" <> Base.url_encode64(Relay.Random.bytes(16), padding: false)
        )

    _ =
      Relay.Process.start_task(fn ->
        case Oban.insert(new(%{"provider" => provider})) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("automatic replay not queued", reason: inspect(reason))
        end
      end)

    Logger.reset_metadata(metadata)
    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # T-29 (6)
  @doc "The replay job changeset of the configured send worker, or `nil` without one."
  @spec replay_job(Relay.Scope.t()) :: (map() -> Ecto.Changeset.t()) | nil
  def replay_job(scope) do
    case Keyword.get(Application.get_env(:relay, Relay.Delivery, []), :send_worker) do
      nil ->
        nil

      worker ->
        fn %{attempt_no: n, dead_letter_id: id, delivery_id: delivery_id} ->
          scope
          |> Relay.Scope.to_job_args()
          |> Map.merge(%{
            "delivery_id" => Relay.Id.to_string(delivery_id),
            "attempt_no" => n,
            "dead_letter_id" => Relay.Id.to_string(id)
          })
          |> worker.new(queue: :dlq_replay, priority: 0)
        end
    end
  end

  # T-29 (6)
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider}}) do
    since =
      DateTime.add(
        Relay.Clock.utc_now(),
        -Relay.Delivery.DeadLetters.auto_replay_window_ms(),
        :millisecond
      )

    rows = Relay.Delivery.Store.dead_letter_auto_replay_scopes(provider, since, @limit)

    replayed =
      rows
      |> Enum.map(&replay_scope(&1, provider, since))
      |> Enum.sum()

    :telemetry.execute([:relay, :dead_letters, :auto_replayed], %{count: replayed}, %{
      provider: provider
    })

    :ok
  end

  defp replay_scope(%{"tenant_id" => tenant_id, "environment" => environment}, provider, since) do
    scope = Relay.Scope.new!(tenant_id, environment)

    with job when job != nil <- replay_job(scope),
         {:ok, ids} <- Relay.Delivery.auto_replay_candidates(scope, provider, since, @limit) do
      Enum.count(ids, fn id ->
        match?(
          {:ok, {:replay_opened, _n}},
          Relay.Delivery.replay_dead_letter(scope, id, job: job)
        )
      end)
    else
      _ -> 0
    end
  end
end
