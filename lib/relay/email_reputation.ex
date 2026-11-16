defmodule Relay.EmailReputation do
  @moduledoc """
  The operation of the e-mail reputation circuit (CH-41, CH-37, CH-85, CH-87), one per tenant environment × sending domain.

    * Counting. A sent e-mail, a delivery to the inbox, a bounce and a complaint are counted in the domain's sliding window on Valkey (`Relay.Platform.reputation_window/5`) with the `reputation` parameters of the active `email_reputation` data set: six hours in equal buckets. The bounce rate is over sent mail and the complaint rate over mail delivered to the inbox; no stop is decided below the minimum volume.
    * Deciding. The pure circuit (`Relay.Channels.reputation_decide/5`) moves the stored state: at a warning threshold the circuit warns and `email_reputation.warning` is published, at a stop threshold it stops and `email_reputation.stopped` is published; a warning circuit whose rates fall back returns to `ok`. The state is a record in PostgreSQL (`relay.email_reputation_circuits`), so a lost Valkey window never reopens a stopped stream.
    * Admitting. While a domain's circuit is stopped its sends are deferred with `email.reputation_stopped` (`admit/2`).
    * Closing. The circuit never closes by itself: a tenant administrator closes it with step-up on the operator surface (`close/4`); the closing is audited as `email_reputation.closed` and `email_reputation.resumed` is published.

  The domain of a sent delivery is remembered on Valkey for the provider events that come later and name only the delivery (`remember/3`, `domain_of/2`).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Channels, Relay.Datasets, Relay.Platform],
    exports: []

  alias Relay.EmailReputation.Store
  alias Relay.Scope

  @remember_ms 7 * 24 * 60 * 60 * 1000
  @states %{"ok" => :ok, "warning" => :warning, "stopped" => :stopped}

  @type event :: :sent | :delivered | :bounce | :complaint

  # CH-87
  @doc "Remembers the sending domain of a sent delivery for its later provider events."
  @spec remember(Scope.t(), Relay.Id.t(), String.t()) :: :ok | {:error, Relay.Error.t()}
  def remember(%Scope{} = scope, delivery_id, domain),
    do: Relay.Platform.put_short_lived(scope, segments(delivery_id), domain, @remember_ms)

  # CH-87
  @doc "The sending domain a delivery was sent from, `nil` when it is not known."
  @spec domain_of(Scope.t(), Relay.Id.t()) ::
          {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def domain_of(%Scope{} = scope, delivery_id),
    do: Relay.Platform.get_short_lived(scope, segments(delivery_id))

  defp segments(delivery_id), do: ["rep", "dlv", Relay.Id.to_string(delivery_id)]

  # CH-41
  # CH-87
  @doc "Counts `count` events of a sending domain and moves its circuit; returns the circuit's state after them."
  @spec count(Scope.t(), String.t(), event(), pos_integer()) ::
          {:ok, :ok | :warning | :stopped} | {:error, term()}
  def count(%Scope{} = scope, domain, event, count \\ 1) when is_binary(domain) do
    with {:ok, params} <- params(),
         {:ok, totals} <- Relay.Platform.reputation_window(scope, domain, event, count, params),
         {:ok, state} <- state(scope, domain) do
      {next, transitions, rates} =
        Relay.Channels.reputation_decide(state, totals, event, count, params)

      if next != state, do: move(scope, domain, next, rates)

      for {kind, _rates} <- transitions do
        :telemetry.execute([:relay, :email, :reputation, kind], %{count: 1}, %{domain: domain})
      end

      {:ok, next}
    end
  end

  defp params do
    case Relay.Datasets.decide(Relay.Datasets.installation_scope(), "email_reputation", & &1) do
      {:ok, {%{"reputation" => params}, _ref}} -> {:ok, params}
      {:error, error} -> {:error, error}
    end
  end

  defp move(scope, domain, next, rates) do
    work = fn _status -> Store.transition(domain, Atom.to_string(next), rates(rates)) end
    Store.in_scope(scope, work)
  end

  defp rates(rates), do: Map.new(rates, fn {key, value} -> {Atom.to_string(key), value} end)

  # CH-87
  @doc "The stored state of a sending domain's circuit, `:ok` without a record."
  @spec state(Scope.t(), String.t()) :: {:ok, :ok | :warning | :stopped} | {:error, term()}
  def state(%Scope{} = scope, domain) do
    case Store.in_scope(scope, fn _status -> Store.circuit(domain) end) do
      {:ok, nil} -> {:ok, :ok}
      {:ok, %{"state" => state}} -> {:ok, Map.fetch!(@states, state)}
      {:error, reason} -> {:error, reason}
    end
  end

  # CH-41
  # CH-87
  @doc "Whether a sending domain may send: `:paused` while its circuit is stopped; a state that cannot be read admits."
  @spec admit(Scope.t(), String.t()) :: :allow | :paused
  def admit(%Scope{} = scope, domain) do
    case state(scope, domain) do
      {:ok, :stopped} -> :paused
      _other -> :allow
    end
  end

  # CH-87
  @doc "The circuits of a scope's sending domains, by domain."
  @spec circuits(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def circuits(%Scope{} = scope), do: Store.in_scope(scope, fn _status -> Store.circuits() end)

  # CH-41
  # CH-87
  @doc "Closes a stopped circuit with the operator's `reason`, audited as `email_reputation.closed`; returns the circuit after it."
  @spec close(Scope.t(), String.t(), String.t(), Relay.Actor.t()) ::
          {:ok, map()} | {:error, :not_found | :not_stopped | term()}
  def close(%Scope{} = scope, domain, reason, %Relay.Actor{} = actor) do
    environment = Relay.Environment.dump(scope.environment)
    record = ["email_reputation.closed", {:bytes, scope.tenant_id}, environment, domain]
    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(record))

    work = fn _status ->
      case Store.close(domain, reason, digest, actor) do
        :closed -> {:ok, Store.circuit(domain)}
        refused -> {:error, refused}
      end
    end

    case Store.in_scope(scope, work) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
