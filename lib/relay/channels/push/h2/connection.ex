defmodule Relay.Channels.Push.H2.Connection do
  @moduledoc """
  One HTTP/2 connection of `Relay.Channels.Push.H2` and its admission control (CH-24, T-37, INV-40).

    * It serves one key only; a request for another key is refused, so different tenants' tokens never travel on one connection.
    * It opens lazily on the first request and stops after `:idle_ms` without work.
    * A semaphore admits at most `min(SETTINGS_MAX_CONCURRENT_STREAMS, :max_streams)` streams, and a single stream until the server's SETTINGS frame has arrived (the first frame a server sends); waiting requests sit in a queue of at most `:max_queue`, and a request past it is refused with `too_many_concurrent_requests`. A queued request whose deadline passes is answered as never sent.
    * The connection is pinged every `:ping_ms`; a pong missing after `:ping_timeout_ms` closes it. After `:max_age_ms`, shortened by a random jitter of up to a fifth, and after a server GOAWAY, it drains: open streams finish, new requests go on a fresh connection.
    * A stream the server refused or left unprocessed is never sent; a stream that ends without an answer, or whose deadline passes, is uncertain.

  Options (`:transport_opts` are passed to Mint, which always verifies the peer certificate on TLS; `:verify` and `:verify_fun` are dropped, T-43): `:max_streams` (1000), `:max_queue` (1000), `:idle_ms` (300 000), `:ping_ms` (60 000), `:ping_timeout_ms` (10 000), `:max_age_ms` (3 600 000), `:connect_timeout_ms` (5 000).
  """

  use GenServer, restart: :temporary

  @defaults [
    max_streams: 1_000,
    max_queue: 1_000,
    idle_ms: 300_000,
    ping_ms: 60_000,
    ping_timeout_ms: 10_000,
    max_age_ms: 3_600_000,
    connect_timeout_ms: 5_000,
    transport_opts: []
  ]

  @doc "The default idle time in milliseconds after which a connection stops."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: Keyword.fetch!(@defaults, :idle_ms)

  # T-45 (6)
  @doc "Starts a connection process through `Relay.TenantWorker`; `args` carries `:key`, `:origin`, `:opts`, `:idle_ms` and `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))
  end

  # T-45 (1)
  @impl GenServer
  def init(args) do
    Process.flag(:message_queue_data, :off_heap)
    opts = Keyword.merge(@defaults, Keyword.get(args, :opts, []))
    idle_ms = Keyword.get(args, :idle_ms, Keyword.fetch!(opts, :idle_ms))
    opts = Keyword.put(opts, :idle_ms, idle_ms)

    state = %{
      key: Keyword.fetch!(args, :key),
      origin: Keyword.fetch!(args, :origin),
      opts: opts,
      conn: nil,
      gen: 0,
      settings?: false,
      expires_at: nil,
      draining: %{},
      streams: %{},
      queue: :queue.new(),
      queued: 0,
      auth: %{},
      ping: nil,
      activity: 0
    }

    _ = Process.send_after(self(), :ping, Keyword.fetch!(opts, :ping_ms))
    {:ok, idle(state)}
  end

  # INV-40
  @impl GenServer
  def handle_call({:request, key, _auth, _request, _deadline}, _from, %{key: own} = state)
      when key != own,
      do: {:reply, {:not_sent, "connection_key_mismatch"}, state}

  def handle_call({:request, _key, auth, request, deadline}, from, state) do
    if state.queued >= Keyword.fetch!(state.opts, :max_queue) do
      {:reply, {:not_sent, "too_many_concurrent_requests"}, state}
    else
      item = %{from: from, auth: auth, request: request, deadline: deadline}
      state = %{state | queue: :queue.in(item, state.queue), queued: state.queued + 1}
      _ = Process.send_after(self(), :sweep, max(deadline - Relay.Clock.monotonic_ms(), 0))
      {:noreply, state |> touch() |> pump() |> idle()}
    end
  end

  @impl GenServer
  def handle_info({:deadline, ref}, state) do
    case Map.pop(state.streams, ref) do
      {nil, _streams} ->
        {:noreply, state}

      {stream, streams} ->
        GenServer.reply(stream.from, {:uncertain, "timeout"})
        state = cancel(%{state | streams: streams}, stream.gen, ref)
        {:noreply, state |> settle() |> pump() |> idle()}
    end
  end

  def handle_info(:sweep, state), do: {:noreply, state |> sweep() |> idle()}

  def handle_info(:ping, state) do
    _ = Process.send_after(self(), :ping, Keyword.fetch!(state.opts, :ping_ms))
    {:noreply, ping(state)}
  end

  def handle_info({:ping_timeout, ref}, %{ping: ref} = state),
    do: {:noreply, state |> drop_current("ping_timeout") |> pump() |> idle()}

  def handle_info({:ping_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:idle, activity}, %{activity: activity} = state) do
    if map_size(state.streams) == 0 and state.queued == 0 do
      _ = close_all(state)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:idle, _activity}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case stream(state, message) do
      {:ok, state} -> {:noreply, state |> settle() |> pump() |> idle()}
      :unknown -> {:noreply, state}
    end
  end

  defp touch(state), do: %{state | activity: state.activity + 1}

  defp idle(state) do
    if map_size(state.streams) == 0 and state.queued == 0 do
      state = touch(state)
      idle_ms = Keyword.fetch!(state.opts, :idle_ms)
      _ = Process.send_after(self(), {:idle, state.activity}, idle_ms)
      state
    else
      state
    end
  end

  # CH-24
  defp pump(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, item}, rest} ->
        if item.deadline <= Relay.Clock.monotonic_ms() do
          GenServer.reply(item.from, {:not_sent, "queue_timeout"})
          pump(%{state | queue: rest, queued: state.queued - 1})
        else
          admit(state, item, rest)
        end
    end
  end

  defp sweep(state) do
    now = Relay.Clock.monotonic_ms()
    {expired, kept} = state.queue |> :queue.to_list() |> Enum.split_with(&(&1.deadline <= now))
    Enum.each(expired, &GenServer.reply(&1.from, {:not_sent, "queue_timeout"}))
    %{state | queue: :queue.from_list(kept), queued: length(kept)}
  end

  defp admit(state, item, rest) do
    case ready(state) do
      {:ok, state} ->
        if open_streams(state) < capacity(state) do
          state = %{state | queue: rest, queued: state.queued - 1}
          state |> send_request(item) |> pump()
        else
          state
        end

      {:error, reason, state} ->
        GenServer.reply(item.from, {:not_sent, reason})
        pump(%{state | queue: rest, queued: state.queued - 1})
    end
  end

  defp capacity(%{settings?: false}), do: 1

  defp capacity(state) do
    server = Mint.HTTP2.get_server_setting(state.conn, :max_concurrent_streams)
    max(min(server, Keyword.fetch!(state.opts, :max_streams)), 1)
  end

  defp open_streams(state),
    do: Enum.count(state.streams, fn {_ref, stream} -> stream.gen == state.gen end)

  defp ready(%{conn: nil} = state), do: connect(state)

  defp ready(state) do
    cond do
      not Mint.HTTP2.open?(state.conn, :write) -> state |> retire() |> connect()
      Relay.Clock.monotonic_ms() >= state.expires_at -> state |> retire() |> connect()
      true -> {:ok, state}
    end
  end

  defp connect(state) do
    {scheme, host, port} = state.origin
    transport = Keyword.drop(Keyword.fetch!(state.opts, :transport_opts), [:verify, :verify_fun])
    timeout = Keyword.fetch!(state.opts, :connect_timeout_ms)

    options = [
      transport_opts: Keyword.put(transport, :timeout, timeout),
      client_settings: [enable_push: false]
    ]

    case Mint.HTTP2.connect(scheme, host, port, options) do
      {:ok, conn} ->
        expires_at = Relay.Clock.monotonic_ms() + age(state.opts)
        gen = state.gen + 1
        state = %{state | conn: conn, gen: gen, settings?: false, ping: nil}
        {:ok, %{state | expires_at: expires_at}}

      {:error, _error} ->
        {:error, "connect_failed", state}
    end
  end

  defp age(opts) do
    max_age = Keyword.fetch!(opts, :max_age_ms)
    jitter = div(max_age, 5)
    if jitter > 0, do: max_age - Relay.Random.uniform(jitter), else: max_age
  end

  defp retire(%{conn: nil} = state), do: state

  defp retire(state),
    do: %{state | draining: Map.put(state.draining, state.gen, state.conn), conn: nil, ping: nil}

  defp send_request(state, item) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    case authorization(state, item.auth, now) do
      {:ok, header, state} ->
        open(state, item, header)

      {:error, reason, state} ->
        GenServer.reply(item.from, {:not_sent, reason})
        state
    end
  end

  defp authorization(state, nil, _now), do: {:ok, nil, state}

  defp authorization(state, {module, config}, now) do
    current = Map.get_lazy(state.auth, module, fn -> module.init(config) end)

    case module.authorization(config, current, now) do
      {:ok, header, next} ->
        {:ok, header, %{state | auth: Map.put(state.auth, module, next)}}

      {:error, error, next} ->
        state = %{state | auth: Map.put(state.auth, module, next)}
        {:error, "auth_unavailable:" <> Atom.to_string(error.code), state}
    end
  end

  defp open(state, item, header) do
    %{method: method, path: path, headers: headers, body: body} = item.request
    headers = if header, do: [{"authorization", header} | headers], else: headers

    case Mint.HTTP2.request(state.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        after_ms = max(item.deadline - Relay.Clock.monotonic_ms(), 1)
        _ = Process.send_after(self(), {:deadline, ref}, after_ms)
        stream = %{from: item.from, gen: state.gen, status: nil, headers: [], data: []}
        %{state | conn: conn, streams: Map.put(state.streams, ref, stream)}

      {:error, conn, %Mint.HTTPError{reason: :too_many_concurrent_requests}} ->
        GenServer.reply(item.from, {:not_sent, "too_many_concurrent_requests"})
        %{state | conn: conn}

      {:error, conn, _error} ->
        GenServer.reply(item.from, {:not_sent, "request_failed"})
        %{state | conn: conn}
    end
  end

  defp ping(%{conn: nil} = state), do: state
  defp ping(%{ping: ref} = state) when ref != nil, do: state

  defp ping(state) do
    case Mint.HTTP2.ping(state.conn) do
      {:ok, conn, ref} ->
        _ = Process.send_after(self(), {:ping_timeout, ref}, ping_timeout(state))
        %{state | conn: conn, ping: ref}

      {:error, conn, _error} ->
        drop_current(%{state | conn: conn}, "ping_failed")
    end
  end

  defp ping_timeout(state), do: Keyword.fetch!(state.opts, :ping_timeout_ms)

  defp stream(state, message) do
    conns = if state.conn, do: [{:current, state.conn}], else: []
    conns = conns ++ Enum.map(state.draining, fn {gen, conn} -> {{:draining, gen}, conn} end)
    Enum.reduce_while(conns, :unknown, fn {which, conn}, :unknown ->
      on(state, which, conn, message)
    end)
  end

  defp on(state, which, conn, message) do
    case Mint.HTTP2.stream(conn, message) do
      :unknown ->
        {:cont, :unknown}

      {:ok, conn, responses} ->
        state = state |> put_conn(which, conn) |> received(which)
        {:halt, {:ok, Enum.reduce(responses, state, &response/2)}}

      {:error, conn, _error, responses} ->
        state = put_conn(state, which, conn)
        {:halt, {:ok, Enum.reduce(responses, state, &response/2)}}
    end
  end

  defp put_conn(state, :current, conn), do: %{state | conn: conn}

  defp put_conn(state, {:draining, gen}, conn),
    do: %{state | draining: Map.put(state.draining, gen, conn)}

  defp received(state, :current), do: %{state | settings?: true}
  defp received(state, _draining), do: state

  defp response({:status, ref, status}, state), do: update(state, ref, &%{&1 | status: status})

  defp response({:headers, ref, headers}, state),
    do: update(state, ref, &%{&1 | headers: &1.headers ++ headers})

  defp response({:data, ref, data}, state), do: update(state, ref, &%{&1 | data: [&1.data, data]})

  defp response({:done, ref}, state) do
    case Map.pop(state.streams, ref) do
      {nil, _streams} ->
        state

      {stream, streams} ->
        answer = %{
          status: stream.status,
          headers: lower(stream.headers),
          body: IO.iodata_to_binary(stream.data)
        }

        GenServer.reply(stream.from, {:ok, answer})
        %{state | streams: streams}
    end
  end

  defp lower(headers),
    do: Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

  defp response({:pong, ref}, %{ping: ref} = state), do: %{state | ping: nil}
  defp response({:pong, _ref}, state), do: state

  defp response({:error, ref, error}, state) do
    case Map.pop(state.streams, ref) do
      {nil, _streams} ->
        state

      {stream, streams} ->
        GenServer.reply(stream.from, stream_error(error))
        %{state | streams: streams}
    end
  end

  defp response(_other, state), do: state

  defp stream_error(%Mint.HTTPError{reason: :unprocessed}), do: {:not_sent, "unprocessed"}

  defp stream_error(%Mint.HTTPError{reason: {:server_closed_request, :refused_stream}}),
    do: {:not_sent, "refused_stream"}

  defp stream_error(_error), do: {:uncertain, "stream_closed"}

  defp update(state, ref, fun) do
    case Map.fetch(state.streams, ref) do
      {:ok, stream} -> %{state | streams: Map.put(state.streams, ref, fun.(stream))}
      :error -> state
    end
  end

  defp cancel(%{gen: gen, conn: conn} = state, gen, ref) when conn != nil do
    case Mint.HTTP2.cancel_request(conn, ref) do
      {:ok, conn} -> %{state | conn: conn}
      {:error, conn, _error} -> %{state | conn: conn}
    end
  end

  defp cancel(state, _gen, _ref), do: state

  defp settle(state) do
    state =
      if state.conn && not Mint.HTTP2.open?(state.conn, :write), do: retire(state), else: state

    draining =
      Enum.reduce(state.draining, state.draining, fn {gen, conn}, acc ->
        cond do
          not Mint.HTTP2.open?(conn, :read) ->
            fail(state.streams, gen, "connection_closed")
            Map.delete(acc, gen)

          not Enum.any?(state.streams, fn {_ref, stream} -> stream.gen == gen end) ->
            _ = Mint.HTTP2.close(conn)
            Map.delete(acc, gen)

          true ->
            acc
        end
      end)

    closed = Map.keys(state.draining) -- Map.keys(draining)
    streams = Map.reject(state.streams, fn {_ref, stream} -> stream.gen in closed end)
    %{state | draining: draining, streams: streams}
  end

  defp drop_current(%{conn: nil} = state, _reason), do: state

  defp drop_current(state, reason) do
    _ = Mint.HTTP2.close(state.conn)
    fail(state.streams, state.gen, reason)
    streams = Map.reject(state.streams, fn {_ref, stream} -> stream.gen == state.gen end)
    %{state | conn: nil, streams: streams, ping: nil, settings?: false}
  end

  defp fail(streams, gen, reason) do
    for {_ref, %{gen: ^gen, from: from}} <- streams,
        do: GenServer.reply(from, {:uncertain, reason})

    :ok
  end

  defp close_all(state) do
    if state.conn, do: Mint.HTTP2.close(state.conn)
    Enum.each(state.draining, fn {_gen, conn} -> Mint.HTTP2.close(conn) end)
  end
end
