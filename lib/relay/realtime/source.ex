defmodule Relay.Realtime.Source do
  @moduledoc """
  Where a realtime stream reads from (IN-24). A source answers from PostgreSQL only: the signal topic that says the subscriber's stream moved, the cursor of the stream's head, the changes after a cursor and the badge counters. Cursors are opaque text; a source tells the reader to resynchronise when a cursor is no longer valid (an epoch change, a position outside the replay window), and marks a page `truncated` when more changes exist than one read may carry (IN-29).

  A change is the event type and its body (`t`, `d`), optionally with the cursor right after it; the connection wraps it in the envelope with the counters (IN-26).
  """

  @type counters :: %{
          unseen: non_neg_integer(),
          unread: non_neg_integer(),
          total: non_neg_integer(),
          version: non_neg_integer()
        }
  @type change :: %{
          required(:t) => String.t(),
          required(:d) => map(),
          optional(:cursor) => String.t()
        }
  @type page :: %{changes: [change()], cursor: String.t(), truncated: boolean()}

  @doc "The signal topic on which the subscriber's stream announces new changes."
  @callback signal_topic(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "The cursor of the stream's head: reading from it returns only later changes."
  @callback head(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "At most `limit` changes after `cursor`, in order."
  @callback changes(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer()) ::
              {:ok, page()} | {:resync_required, String.t()} | {:error, term()}

  @doc "The subscriber's badge counters."
  @callback counters(Relay.Scope.t(), Relay.Id.t()) :: {:ok, counters()} | {:error, term()}
end
