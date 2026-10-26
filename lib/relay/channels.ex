defmodule Relay.Channels do
  @moduledoc """
  Channel adapters, providers and failover, and the node-local circuit breakers of the providers. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Channels.Breaker

  @doc "Supervised children: the owner of the circuit breaker table."
  @spec children() :: [Supervisor.child_spec()]
  def children, do: [Supervisor.child_spec(Breaker, [])]

  # T-25
  # INV-40
  @doc "Asks the provider and tenant breakers whether a call may go; see `Relay.Channels.Breaker.check/3`."
  @spec check_breaker(Relay.ChannelParameters.t(), Breaker.target(), integer()) ::
          {Breaker.decision(), Breaker.ticket()}
  def check_breaker(parameters, target, now \\ Relay.Clock.monotonic_ms()),
    do: Breaker.check(parameters, target, now)

  # T-25
  @doc "Records the outcome of a call the breakers admitted; see `Relay.Channels.Breaker.record/4`."
  @spec record_breaker(Breaker.ticket(), Breaker.outcome(), non_neg_integer() | nil, integer()) ::
          :ok
  def record_breaker(ticket, outcome, latency_ms \\ nil, now \\ Relay.Clock.monotonic_ms()),
    do: Breaker.record(ticket, outcome, latency_ms, now)

  # T-26
  # INV-13
  @doc """
  Sends one provider HTTP request. The client never retries and never follows redirects, whatever the options say: the only retry authority is the job queue (T-26), and a retry is a new job that reuses the attempt's provider idempotency key.
  """
  @spec http_request(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def http_request(opts) when is_list(opts) do
    :ok = Relay.NetworkGuard.check!(:http)

    opts
    |> Keyword.drop([:retry, :max_retries, :retry_delay, :retry_log_level, :redirect])
    |> Keyword.merge(retry: false, redirect: false)
    |> Req.request()
  end
end
