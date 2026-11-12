defmodule Relay.Agents.Correlation do
  @moduledoc """
  The stored form of a correlation key (AG-65). A correlation key is a free value of the tenant and may carry personal data, while waitpoints and mailbox records are immutable and outlive subject erasure, so the key is never stored in clear: a waitpoint, a buffered early event and a subscriber's event wait keep `HMAC-SHA256` of the canonical encoding of the event type and the key, computed inside the key store under the tenant × environment blind index key (`Relay.Tenancy.blind_index_digests/3`, purpose `correlation`, TN-63), and the first matching stage (AG-14) compares those digests.

  While a blind index key is rotated a key has one digest per readable key, the current key first: a new row stores the first, matching and the advisory lock use all of them. The key store is called outside any transaction, so the digests are computed before the transaction that opens a waitpoint or offers an event.
  """

  alias Relay.Agents.WaitpointStore

  @purpose "correlation"

  @type digest :: <<_::256>>
  @type pair :: {String.t(), String.t()}

  # AG-65
  # TN-33
  # TN-63
  @doc "The digests of an event type and a correlation key under every readable lookup key of the scope, the current key first; computed outside any transaction."
  @spec digests(Relay.Scope.t(), String.t(), String.t()) ::
          {:ok, [digest(), ...]} | {:error, Relay.Error.t()}
  def digests(%Relay.Scope{} = scope, event_type, key)
      when is_binary(event_type) and is_binary(key) do
    index = %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: @purpose}

    case Relay.Tenancy.blind_index_digests(index, Relay.Canonical.encode!([event_type, key])) do
      {:ok, entries} -> {:ok, Enum.map(entries, &elem(&1, 1))}
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  # AG-65
  @doc "Converts up to `limit` waitpoints and up to `limit` mailbox records of a scope that still hold a correlation key in clear: reads them in one transaction, computes the digests under the current lookup key outside it and writes them in another, which clears the key. Converted rows drop out of the next read, so a repeated call goes on where the last one stopped."
  @spec backfill(Relay.Scope.t(), pos_integer()) ::
          {:ok, %{scanned: non_neg_integer(), updated: non_neg_integer()}} | {:error, term()}
  def backfill(%Relay.Scope{} = scope, limit) do
    read = fn _status -> WaitpointStore.plain_batch(limit) end

    with {:ok, rows} <- WaitpointStore.in_scope(scope, read),
         {:ok, digests} <- digest_map(scope, for({_, _, _, type, key} <- rows, do: {type, key})),
         {:ok, updated} <- fill(scope, rows, digests) do
      {:ok, %{scanned: length(rows), updated: updated}}
    end
  end

  defp fill(_scope, [], _digests), do: {:ok, 0}

  defp fill(scope, rows, digests) do
    filled =
      for {source, id, created_at, type, key} <- rows,
          do: {source, id, created_at, hd(Map.fetch!(digests, {type, key}))}

    WaitpointStore.in_scope(scope, fn _status -> WaitpointStore.digest_fill(filled) end)
  end

  # AG-65
  @doc "The digests of several pairs of event type and correlation key, keyed by the pair; computed outside any transaction."
  @spec digest_map(Relay.Scope.t(), [pair()]) ::
          {:ok, %{pair() => [digest(), ...]}} | {:error, Relay.Error.t()}
  def digest_map(%Relay.Scope{} = scope, pairs) when is_list(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn {type, key} = pair, {:ok, acc} ->
      case digests(scope, type, key) do
        {:ok, digests} -> {:cont, {:ok, Map.put(acc, pair, digests)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
