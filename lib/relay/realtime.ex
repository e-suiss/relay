defmodule Relay.Realtime do
  @moduledoc """
  The realtime feed of a subscriber's inbox (IN-22…IN-37): one stream carried equally by WebSocket, SSE and long-poll inside the Relay endpoint (IN-23). The truth stays in PostgreSQL; a Valkey signal says only that the stream moved and the connection reads the change from its cursor, so a lost signal costs latency, never an event (IN-24, INV-53). The stream reads from a `Relay.Realtime.Source`, by default the inbox (`Relay.Realtime.InboxSource`).

  Each node limits how fast it accepts new connections (`admit/0`, IN-52), and every WebSocket or SSE connection keeps a short-lived entry in the subscriber's connection set on Valkey, refreshed by its heartbeat; the set holds at most the contract's connections per subscriber and drops the oldest beyond it. `connected?/3` reads that set for the push decision of IN-40. Other contexts use only the functions of this module.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform],
    exports: [Admission, Connections, Envelope, Feed, Source]

  alias Relay.Realtime.Admission
  alias Relay.Realtime.Connections

  @type stream :: :inbox | {:opaque, String.t()}

  # IN-52
  @doc "Supervised children: the node's connection admission bucket."
  @spec children() :: [module(), ...]
  def children, do: [Admission]

  # IN-34
  # IN-52
  @doc "Takes one new connection from this node's accept rate; when none is left, the jittered `Retry-After` seconds."
  @spec admit() :: :ok | {:error, pos_integer()}
  def admit, do: Admission.take()

  # IN-40
  @doc "True when the subscriber's device has a live WebSocket or SSE connection on any node. A Valkey failure, an unknown device or a missing entry is `false`, so the caller sends the push."
  @spec connected?(Relay.Scope.t(), Relay.Id.t(), String.t()) :: boolean()
  def connected?(scope, subscriber_id, device_id),
    do: Connections.connected?(scope, subscriber_id, device_id)

  # IN-23
  @doc "The configured stream source module (`config :relay, Relay.Realtime, source: module`)."
  @spec source() :: module()
  def source do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:source, Relay.Realtime.InboxSource)
  end

  # IN-32
  # IN-37
  @doc "True when a subscriber token's scopes let a connection carry `stream`: the inbox needs `inbox:read`. An opaque payload stream (IN-37) follows the same `(stream, epoch, seq)` model and authorization, but no subscriber token scope grants one yet, so none is permitted."
  @spec permitted?([String.t()], stream()) :: boolean()
  def permitted?(scopes, :inbox) when is_list(scopes), do: "inbox:read" in scopes
  def permitted?(scopes, {:opaque, _kind}) when is_list(scopes), do: false
end
