defmodule Relay.Platform.ReputationWindow do
  @moduledoc """
  The sliding e-mail reputation counters of a tenant environment's sending domain on Valkey (CH-41, CH-87): one hash per domain whose fields are `<bucket>:<event>` counts, buckets of `bucket_ms` on the server's `TIME`, the oldest trimmed once they leave the window of `buckets` buckets (`priv/valkey/reputation.lua`). The events are sent, delivered (to the inbox), bounce and complaint. A call adds a count and returns the window's totals before it, with the server time; a read adds nothing.

  Keys are `relay:t:<tenant>:<environment>:rep:<domain>` and expire a minute after the window. Valkey holds no record of truth: a lost window only delays a warning or a stop, it never closes a stopped circuit.
  """

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script

  @external_resource Script.path("reputation")
  @script Script.read!("reputation")
  @events %{sent: 1, delivered: 2, bounce: 3, complaint: 4}

  @type event :: :sent | :delivered | :bounce | :complaint
  @type totals :: %{
          now_ms: non_neg_integer(),
          sent: non_neg_integer(),
          delivered: non_neg_integer(),
          bounces: non_neg_integer(),
          complaints: non_neg_integer()
        }

  # T-9
  @doc "The script this module runs, for `SCRIPT LOAD` at start."
  @spec scripts() :: [Script.t()]
  def scripts, do: [@script]

  # CH-87
  @doc "Adds `count` events to a domain's window (`nil` reads only) and returns the totals of the window before them."
  @spec record(Relay.Scope.t(), String.t(), event() | nil, non_neg_integer(), map(), module()) ::
          {:ok, totals()} | {:error, Relay.Error.t()}
  def record(%Relay.Scope{} = scope, domain, event, count, params, adapter \\ Valkey.adapter()) do
    %{"window_ms" => window_ms, "buckets" => buckets} = params
    bucket_ms = max(div(window_ms, buckets), 1)
    args = [Map.get(@events, event, 0), count, bucket_ms, buckets]

    with {:ok, key} <- key(scope, domain, window_ms) do
      case Valkey.eval(@script, key, args, adapter) do
        {:ok, [now, sent, delivered, bounces, complaints]} ->
          {:ok,
           %{
             now_ms: now,
             sent: sent,
             delivered: delivered,
             bounces: bounces,
             complaints: complaints
           }}

        {:ok, _other} ->
          {:error, Relay.Error.new(:valkey_reply, "unexpected reputation window reply")}

        {:error, _} = error ->
          error
      end
    end
  end

  defp key(scope, domain, window_ms) do
    segment =
      if Key.segment?(domain),
        do: domain,
        else: :sha256 |> :crypto.hash(domain) |> Base.encode16(case: :lower)

    Key.new(
      Relay.Id.to_string(scope.tenant_id),
      Relay.Environment.dump(scope.environment),
      ["rep", segment],
      window_ms + 60_000
    )
  end
end
