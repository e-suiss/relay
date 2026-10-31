defmodule Relay.Connectors.Outbox do
  @moduledoc """
  The outbox source of an ingest connector (T-41): a Broadway producer that reads the producer's transactional outbox table in its own PostgreSQL database, and the acknowledger that records the outcome there. It needs nothing beyond PostgreSQL (T-7).

  The table belongs to the producer and has at least these columns; Relay reads and updates rows and never deletes one:

      id                  bigint PRIMARY KEY
      payload             jsonb NOT NULL      -- one structured mode CloudEvent
      relay_claimed_until timestamptz NULL
      relayed_at          timestamptz NULL
      relay_outcome       text NULL

  Rows are taken by state, not by an id cursor (L-42): a batch is the oldest rows with `relayed_at IS NULL` whose claim is absent or expired, claimed for `lease_s` seconds with `FOR UPDATE SKIP LOCKED`, so several nodes share one table without taking the same row twice. When a row's event is accepted, `relayed_at` is set and `relay_outcome` is `accepted`; when it can never be accepted, `relayed_at` is set and `relay_outcome` is the error code. A row whose message is neither (a node stopped, the outcome could not be written) keeps its claim until it expires and is taken again; the idempotency key of its event makes that harmless. Times are the source database's clock.

  Options: `hostname`, `port` (5432), `database`, `username`, `password_file` (read at every connect, never stored; `Relay.Config.SecretFiles.configure_path/2`), `ssl` (`false`, `true` or `:ssl` options; peer verification cannot be turned off), `table` (`name` or `schema.name`), `poll_ms` (1000), `batch_size` (100) and `lease_s` (60).
  """

  use GenStage

  @behaviour Broadway.Producer
  @behaviour Broadway.Acknowledger

  require Logger

  alias Broadway.Message
  alias Relay.Config.Error
  alias Relay.Connectors.OutboxStore

  @keys [
    :hostname,
    :port,
    :database,
    :username,
    :password_file,
    :ssl,
    :table,
    :poll_ms,
    :batch_size,
    :lease_s
  ]
  @identifier ~r/\A[a-z_][a-z0-9_]{0,62}(\.[a-z_][a-z0-9_]{0,62})?\z/
  @accepted "accepted"

  # T-41
  # TN-67 (3)
  @doc "Checks the options of an outbox source; raises `Relay.Config.Error` when they are invalid."
  @spec options!(atom(), term()) :: keyword()
  def options!(name, options) do
    keys!(name, options)

    [
      hostname: options[:hostname],
      port: integer!(name, :port, Keyword.get(options, :port, 5432), 1, 65_535),
      database: options[:database],
      username: options[:username],
      password_file: options[:password_file],
      ssl: ssl!(name, Keyword.get(options, :ssl, false)),
      table: table!(name, options[:table]),
      poll_ms: integer!(name, :poll_ms, Keyword.get(options, :poll_ms, 1000), 10, 60_000),
      batch_size: integer!(name, :batch_size, Keyword.get(options, :batch_size, 100), 1, 500),
      lease_s: integer!(name, :lease_s, Keyword.get(options, :lease_s, 60), 5, 3600)
    ]
  end

  defp keys!(name, options) do
    unless Keyword.keyword?(options),
      do: raise(Error, "connector #{name}: options are a keyword list")

    case Keyword.keys(options) -- @keys do
      [] -> :ok
      unknown -> raise Error, "connector #{name}: unknown outbox options #{inspect(unknown)}"
    end

    for key <- [:hostname, :database, :username, :password_file],
        not (is_binary(options[key]) and options[key] != ""),
        do: raise(Error, "connector #{name}: #{key} is required")

    :ok
  end

  defp table!(name, table) do
    if is_binary(table) and Regex.match?(@identifier, table),
      do: table,
      else: raise(Error, "connector #{name}: table is a lowercase name or schema.name")
  end

  defp ssl!(name, ssl) do
    cond do
      is_boolean(ssl) ->
        ssl

      not Keyword.keyword?(ssl) ->
        raise Error, "connector #{name}: ssl is a boolean or :ssl options"

      Keyword.get(ssl, :verify) == :verify_none ->
        raise Error, "connector #{name}: TLS peer verification cannot be turned off"

      true ->
        ssl
    end
  end

  defp integer!(_name, _key, value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp integer!(name, key, _value, min, max),
    do: raise(Error, "connector #{name}: #{key} is an integer from #{min} to #{max}")

  @impl GenStage
  def init(opts) do
    connection = [
      hostname: opts[:hostname],
      port: opts[:port],
      database: opts[:database],
      username: opts[:username],
      ssl: opts[:ssl],
      pool_size: 2,
      parameters: [application_name: "relay_connector"],
      configure: {Relay.Config.SecretFiles, :configure_path, [opts[:password_file]]}
    ]

    {:ok, conn} = Postgrex.start_link(connection)

    {:producer,
     %{
       conn: conn,
       table: OutboxStore.quoted_table(opts[:table]),
       poll_ms: opts[:poll_ms],
       batch_size: opts[:batch_size],
       lease_s: opts[:lease_s],
       demand: 0,
       timer: nil,
       draining: false
     }}
  end

  @impl GenStage
  def handle_demand(incoming, state), do: fetch(%{state | demand: state.demand + incoming})

  @impl GenStage
  def handle_info(:poll, state), do: fetch(%{state | timer: nil})
  def handle_info(_message, state), do: {:noreply, [], state}

  @impl Broadway.Producer
  def prepare_for_draining(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, [], %{state | timer: nil, draining: true}}
  end

  defp fetch(%{draining: true} = state), do: {:noreply, [], state}
  defp fetch(%{demand: 0} = state), do: {:noreply, [], state}

  defp fetch(state) do
    limit = min(state.demand, state.batch_size)

    rows =
      case OutboxStore.claim(state.conn, state.table, limit, state.lease_s) do
        {:ok, rows} ->
          rows

        {:error, reason} ->
          Logger.warning("outbox source unavailable", reason: inspect(reason.__struct__))
          []
      end

    messages = Enum.map(rows, &message(&1, state))
    state = %{state | demand: state.demand - length(messages)}
    delay = if length(rows) == limit, do: 0, else: state.poll_ms
    {:noreply, messages, schedule(state, delay)}
  end

  defp schedule(%{demand: 0} = state, _delay), do: state
  defp schedule(%{timer: timer} = state, _delay) when timer != nil, do: state
  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :poll, delay)}

  defp message({id, payload}, state) do
    %Message{
      data: payload,
      metadata: %{outbox_id: id},
      acknowledger: {__MODULE__, {state.conn, state.table}, id}
    }
  end

  # T-41
  # INV-2
  @impl Broadway.Acknowledger
  def ack({conn, table}, successful, failed) do
    finish(conn, table, Enum.map(successful, &id/1), @accepted)

    failed
    |> Enum.flat_map(fn
      %Message{status: {:failed, code}} = message when is_binary(code) -> [{code, id(message)}]
      _crashed -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {code, ids} -> finish(conn, table, ids, code) end)
  end

  defp finish(_conn, _table, [], _outcome), do: :ok

  defp finish(conn, table, ids, outcome) do
    case OutboxStore.finish(conn, table, ids, outcome) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("outbox outcome not recorded", reason: inspect(reason.__struct__))
    end
  catch
    :exit, _reason -> Logger.warning("outbox outcome not recorded", reason: "exit")
  end

  defp id(%Message{acknowledger: {_module, _ref, id}}), do: id
end
