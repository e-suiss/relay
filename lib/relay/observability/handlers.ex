defmodule Relay.Observability.Handlers do
  @moduledoc """
  Telemetry handlers that derive the observability events from the platform's own events. A finished API request is counted against the budget of its request type (`[:relay, :request, :budget]` with `%{type, good}` and `[:relay, :request, :budget_breach]` with `%{type, resource}`), an accepted single event against the accept latency threshold of its message class (`[:relay, :slo, :accept]` with `%{class, good}`), and its API client in the noisy neighbour window. A finished job is counted for its tenant (`[:relay, :jobs, :processed]` with `%{queue, tenant}`, the tenant label bounded). A provider breaker transition becomes the provider's breaker state (`[:relay, :breaker, :state]` with `%{open}` and `%{provider}`). A kill switch that took effect is counted against the effect target (`[:relay, :slo, :kill_switch]` with `%{platform, good}`).
  """

  alias Relay.Observability.Budget
  alias Relay.Observability.Slo
  alias Relay.Observability.TopTenants

  @handler {__MODULE__, :observability}
  @reductions {__MODULE__, :reductions}
  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:relay, :breaker, :transition],
    [:relay, :kill_switch, :effective]
  ]

  # OP-36
  # T-68 (3)
  # TN-62
  @doc "Attaches the handlers once; a second call leaves them attached."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # OP-36
  # T-68 (3)
  # TN-62
  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:phoenix, :endpoint, :start], _measurements, _meta, _config) do
    {:reductions, reductions} = Process.info(self(), :reductions)
    Process.put(@reductions, reductions)
    :ok
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    {:reductions, now} = Process.info(self(), :reductions)
    reductions = now - (Process.delete(@reductions) || now)

    budget(conn, duration_ms, reductions)
    accept(conn, duration_ms)
    client(conn)
  end

  def handle_event([:oban, :job, event], _measurements, %{job: job}, _config)
      when event in [:stop, :exception] do
    case job.args do
      %{"tenant_id" => tenant} when is_binary(tenant) ->
        TopTenants.count_job(job.queue, tenant)
        meta = %{queue: job.queue, tenant: TopTenants.label(tenant)}
        :telemetry.execute([:relay, :jobs, :processed], %{count: 1}, meta)

      _args ->
        :ok
    end
  end

  def handle_event([:relay, :breaker, :transition], _measurements, meta, _config) do
    case meta do
      %{level: :provider, provider: provider, to: to} ->
        open = if to == :open, do: 1, else: 0
        :telemetry.execute([:relay, :breaker, :state], %{open: open}, %{provider: provider})

      _tenant_level ->
        :ok
    end
  end

  def handle_event([:relay, :kill_switch, :effective], %{duration_ms: ms}, meta, _config) do
    good = ms <= Slo.kill_switch_effect_seconds() * 1000
    meta = %{platform: Map.get(meta, :platform, false), good: good}
    :telemetry.execute([:relay, :slo, :kill_switch], %{count: 1}, meta)
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp budget(conn, duration_ms, reductions) do
    request = %{
      method: conn.method,
      path_info: conn.path_info,
      operation: conn.private[:relay_operation]
    }

    case Budget.classify(request) do
      nil ->
        :ok

      type ->
        breaches = Budget.breaches(type, duration_ms, reductions)
        meta = %{type: type, good: breaches == []}
        :telemetry.execute([:relay, :request, :budget], %{count: 1}, meta)

        for resource <- breaches do
          meta = %{type: type, resource: resource}
          :telemetry.execute([:relay, :request, :budget_breach], %{count: 1}, meta)
        end

        :ok
    end
  end

  defp accept(%{status: status} = conn, duration_ms) when is_integer(status) and status < 500 do
    case conn.private[:relay_message_class] do
      nil ->
        :ok

      class ->
        meta = %{class: class, good: Slo.accept_good?(class, duration_ms)}
        :telemetry.execute([:relay, :slo, :accept], %{count: 1}, meta)
    end
  end

  defp accept(_conn, _duration_ms), do: :ok

  defp client(conn) do
    case conn.assigns[:principal] do
      %{api_client_id: client} when is_binary(client) -> TopTenants.count_client(client)
      _none -> :ok
    end
  end
end
