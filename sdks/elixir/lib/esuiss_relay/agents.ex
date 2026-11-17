defmodule EsuissRelay.Agents do
  @moduledoc """
  Helpers for agents and the API clients that wait on them: waitpoints, the durable mailbox
  and the "open the stream, read the history, deduplicate by id" pattern.

  A push, webhook or protocol notification is only a hint to wake up; the records wait in the
  mailbox and the state of a waitpoint is read from Relay. `follow/4` opens the hint stream
  first, then reads what the mailbox already holds, then reads again on every hint, and hands
  each record to the handler once by its id.
  """

  alias EsuissRelay.Agents.Feed
  alias EsuissRelay.Api
  alias EsuissRelay.Client
  alias EsuissRelay.Error

  @open_states ["open", "stalled"]

  # X-30
  @doc "Opens a waitpoint. The idempotency key is the waitpoint's identity across retries."
  @spec create_waitpoint(Client.t(), map(), keyword()) :: Client.result()
  def create_waitpoint(client, body, opts \\ []), do: Api.create_waitpoint(client, body, opts)

  # X-30
  @doc """
  Waits until a waitpoint is no longer open or stalled and returns it. Options: `:timeout` in
  milliseconds (default 300_000) and `:poll_interval` in milliseconds (default 2_000). When the
  time runs out the result is `{:error, %EsuissRelay.WaitTimeoutError{}}` with the last state.
  """
  @spec await_waitpoint(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | EsuissRelay.WaitTimeoutError.t()}
  def await_waitpoint(%Client{} = client, waitpoint_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    interval = Keyword.get(opts, :poll_interval, 2_000)
    poll(client, waitpoint_id, interval, client.monotonic.() + timeout)
  end

  defp poll(client, waitpoint_id, interval, deadline) do
    with {:ok, waitpoint} <- Api.get_waitpoint(client, waitpoint_id) do
      cond do
        waitpoint["state"] not in @open_states ->
          {:ok, waitpoint}

        client.monotonic.() + interval > deadline ->
          {:error, %EsuissRelay.WaitTimeoutError{waitpoint: waitpoint}}

        true ->
          client.sleep.(interval)
          poll(client, waitpoint_id, interval, deadline)
      end
    end
  end

  # X-30
  @doc "Takes at most `max` records of the caller's mailbox with a lease."
  @spec lease(Client.t(), pos_integer(), keyword()) :: Client.result()
  def lease(client, max \\ 1, opts \\ []),
    do: Api.lease_mailbox_records(client, Keyword.put(opts, :body, %{"max" => max}))

  # X-30
  @doc "Acknowledges records of one lease."
  @spec ack(Client.t(), String.t(), [String.t()], keyword()) :: Client.result()
  def ack(client, lease_id, record_ids, opts \\ []),
    do: Api.ack_mailbox_records(client, %{"lease_id" => lease_id, "record_ids" => record_ids}, opts)

  # X-30
  @doc "Reads mailbox records after a position (`:since`), without a lease."
  @spec read(Client.t(), keyword()) :: Client.result()
  def read(client, opts \\ []), do: Api.list_mailbox_records(client, opts)

  # X-30
  @doc """
  Follows the caller's mailbox. `open_hints` is called first and returns the enumerable of wake
  hints (webhook deliveries, push messages, anything); then the records the mailbox already
  holds are read, and they are read again after every hint. Each record reaches `handler` once
  by its id. Returns `{:ok, feed}` when the hints end.

  Options: `:since` (start position; default the acknowledged position) and `:dedupe_limit`
  (default 10_000 ids).
  """
  @spec follow(Client.t(), (-> Enumerable.t()), (map() -> any()), keyword()) ::
          {:ok, Feed.t()} | {:error, Error.t()}
  def follow(%Client{} = client, open_hints, handler, opts \\ [])
      when is_function(open_hints, 0) and is_function(handler, 1) do
    hints = open_hints.()
    feed = Feed.new(opts)

    with {:ok, feed} <- deliver(client, feed, handler) do
      Enum.reduce_while(hints, {:ok, feed}, fn _hint, {:ok, feed} ->
        case deliver(client, feed, handler) do
          {:ok, feed} -> {:cont, {:ok, feed}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp deliver(client, feed, handler) do
    with {:ok, records, feed} <- Feed.sync(feed, client) do
      Enum.each(records, handler)
      {:ok, feed}
    end
  end
end

defmodule EsuissRelay.Agents.Feed do
  @moduledoc """
  The read position and the seen ids of a mailbox reader. `sync/2` reads every record after
  the position, page by page, starts over from the returned cursor when Relay says the position
  no longer holds, and returns only the records not seen before.
  """

  alias EsuissRelay.Api
  alias EsuissRelay.Client
  alias EsuissRelay.Dedupe
  alias EsuissRelay.Error

  defstruct cursor: nil, dedupe: Dedupe.new()

  @type t :: %__MODULE__{cursor: String.t() | nil, dedupe: Dedupe.t()}

  @doc "A reader at `:since` (default the acknowledged position)."
  @spec new(keyword()) :: t()
  def new(opts \\ []),
    do: %__MODULE__{
      cursor: Keyword.get(opts, :since),
      dedupe: Dedupe.new(Keyword.get(opts, :dedupe_limit, 10_000))
    }

  # X-30
  @doc "Reads the records after the position and returns the new ones."
  @spec sync(t(), Client.t()) :: {:ok, [map()], t()} | {:error, Error.t()}
  def sync(%__MODULE__{} = feed, client), do: sync(feed, client, [], 0)

  defp sync(feed, client, acc, rounds) do
    opts = if feed.cursor, do: [since: feed.cursor], else: []

    with {:ok, page} <- Api.list_mailbox_records(client, opts) do
      {fresh, dedupe} = fresh(page["records"] || [], feed.dedupe)
      feed = %{feed | cursor: page["cursor"] || feed.cursor, dedupe: dedupe}
      acc = acc ++ fresh

      if (page["has_more"] == true or page["resync_required"] == true) and rounds < 1_000,
        do: sync(feed, client, acc, rounds + 1),
        else: {:ok, acc, feed}
    end
  end

  defp fresh(records, dedupe) do
    Enum.flat_map_reduce(records, dedupe, fn record, dedupe ->
      case Dedupe.first?(dedupe, record["id"]) do
        {true, dedupe} -> {[record], dedupe}
        {false, dedupe} -> {[], dedupe}
      end
    end)
  end
end

defmodule EsuissRelay.WaitTimeoutError do
  @moduledoc "The waitpoint was still open when the wait ran out; `waitpoint` is its last state."
  defexception [:waitpoint]

  @type t :: %__MODULE__{waitpoint: map() | nil}

  @impl true
  def message(_error), do: "the waitpoint is still open"
end
