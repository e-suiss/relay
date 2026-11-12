defmodule Relay.Realtime.Envelope do
  @moduledoc """
  The one realtime envelope (IN-26): `t` the event type, `v` its schema version, `ts` the server time, `d` the body, and on every message the badge `counters`, so a badge never depends on a separate message. `id` is the opaque cursor right after the message, the SSE event id and the resume position of every transport; it is left out where a batch carries it only on its last message. No tenant identifier is ever part of an envelope (IN-32).
  """

  alias Relay.Realtime.Source

  @version 1
  @types ~w(inbox.item_created inbox.item_updated inbox.items_bulk_updated inbox.counters_changed stream.resync_required)

  @type t :: %{required(String.t()) => term()}

  # IN-26
  @doc "The event types of the human inbox stream."
  @spec types() :: [String.t(), ...]
  def types, do: @types

  # IN-26
  # IN-27
  @doc "Builds an envelope; `id` is left out when `nil`."
  @spec build(String.t(), map(), Source.counters(), String.t() | nil, DateTime.t()) :: t()
  def build(type, data, counters, id, %DateTime{} = now) when type in @types and is_map(data) do
    envelope = %{
      "t" => type,
      "v" => @version,
      "ts" => now |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "d" => data,
      "counters" => counters(counters)
    }

    if is_binary(id), do: Map.put(envelope, "id", id), else: envelope
  end

  # IN-26
  @doc "The counters as an envelope carries them, also the body of `inbox.counters_changed`."
  @spec counters(Source.counters()) :: %{String.t() => non_neg_integer()}
  def counters(%{unseen: unseen, unread: unread, total: total, version: version}),
    do: %{"unseen" => unseen, "unread" => unread, "total" => total, "version" => version}
end
