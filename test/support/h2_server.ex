defmodule RelayTest.H2Server do
  @moduledoc """
  An in-process HTTP/2 server for the push client tests: prior-knowledge cleartext HTTP/2 on a local port, nothing reaches the network. Every connection is a process; each complete request is sent to the test process as `{:h2_request, connection, stream_id, request}` with its lower-case headers and body, and answered by the handler: `{status, headers, body}`, or `:hold` to wait for `release/3`.

  Options: `:max_concurrent_streams` (100) and `:settings_delay_ms` (0) shape the server's SETTINGS frame, `:pong` (true) whether pings are answered. SETTINGS is always the first frame the server sends: without a delay it follows the client preface at once, and an answer or a GOAWAY due before the delay has passed sends it first.
  """

  use Boundary, top_level?: true, check: [out: false]

  import Bitwise

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @doc "Starts a server answering with `handler`; returns its port."
  @spec start((map() -> term()), keyword()) :: {:ok, :inet.port_number()}
  def start(handler, opts \\ []) when is_function(handler, 1) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    {:ok, _pid} = Task.start(fn -> accept(listen, test, handler, opts) end)
    {:ok, port}
  end

  @doc "Answers a held stream of a connection."
  @spec release(pid(), pos_integer(), {pos_integer(), list(), binary()}) :: :ok
  def release(connection, stream_id, response) do
    send(connection, {:release, stream_id, response})
    :ok
  end

  @doc "Sends a GOAWAY frame naming the last stream the connection processes."
  @spec goaway(pid(), non_neg_integer()) :: :ok
  def goaway(connection, last_stream_id) do
    send(connection, {:goaway, last_stream_id})
    :ok
  end

  defp accept(listen, test, handler, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} = Task.start(fn -> serve(socket, test, handler, opts) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, test, handler, opts)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, test, handler, opts) do
    receive do
      :go -> :ok
    end

    {:ok, @preface} = :gen_tcp.recv(socket, byte_size(@preface), 5_000)
    send(test, {:h2_connected, self()})
    :ok = :inet.setopts(socket, active: :once)

    state = %{
      socket: socket,
      test: test,
      handler: handler,
      opts: opts,
      buffer: "",
      decode: HPAX.new(4096),
      encode: HPAX.new(4096),
      streams: %{},
      settings?: false,
      ack?: false
    }

    case Keyword.get(opts, :settings_delay_ms, 0) do
      0 ->
        loop(settings(state))

      delay ->
        _ = Process.send_after(self(), :settings, delay)
        loop(state)
    end
  end

  defp settings(%{settings?: true} = state), do: state

  defp settings(state) do
    max = Keyword.get(state.opts, :max_concurrent_streams, 100)
    :ok = :gen_tcp.send(state.socket, frame(4, 0, 0, <<3::16, max::32>>))
    if state.ack?, do: :ok = :gen_tcp.send(state.socket, frame(4, 1, 0, ""))
    %{state | settings?: true, ack?: false}
  end

  defp loop(state) do
    receive do
      {:tcp, _socket, data} ->
        :ok = :inet.setopts(state.socket, active: :once)
        state |> Map.update!(:buffer, &(&1 <> data)) |> frames() |> loop()

      {:tcp_closed, _socket} ->
        :ok

      :settings ->
        loop(settings(state))

      {:release, stream_id, response} ->
        loop(respond(state, stream_id, response))

      {:goaway, last} ->
        state = settings(state)
        :ok = :gen_tcp.send(state.socket, frame(7, 0, 0, <<0::1, last::31, 0::32>>))
        loop(state)
    end
  end

  defp frames(%{buffer: <<len::24, type::8, flags::8, _::1, id::31, rest::binary>>} = state)
       when byte_size(rest) >= len do
    <<payload::binary-size(^len), rest::binary>> = rest
    state = %{state | buffer: rest}
    state |> handle(type, flags, id, payload) |> frames()
  end

  defp frames(state), do: state

  defp handle(state, 4, flags, 0, _payload) do
    cond do
      (flags &&& 1) != 0 ->
        state

      state.settings? ->
        :ok = :gen_tcp.send(state.socket, frame(4, 1, 0, ""))
        state

      true ->
        %{state | ack?: true}
    end
  end

  defp handle(state, 6, flags, 0, payload) do
    if (flags &&& 1) == 0 and state.settings? and Keyword.get(state.opts, :pong, true),
      do: :ok = :gen_tcp.send(state.socket, frame(6, 1, 0, payload))

    state
  end

  defp handle(state, 1, flags, id, hbf) do
    stream = %{hbf: hbf, body: "", headers: nil}
    state = %{state | streams: Map.put(state.streams, id, stream)}
    state = if (flags &&& 4) != 0, do: headers(state, id), else: state
    if (flags &&& 1) != 0, do: complete(state, id), else: state
  end

  defp handle(state, 9, flags, id, hbf) do
    state = update_in(state.streams[id].hbf, &(&1 <> hbf))
    if (flags &&& 4) != 0, do: headers(state, id), else: state
  end

  defp handle(state, 0, flags, id, data) do
    case state.streams do
      %{^id => _stream} ->
        state = update_in(state.streams[id].body, &(&1 <> data))
        if (flags &&& 1) != 0, do: complete(state, id), else: state

      _other ->
        state
    end
  end

  defp handle(state, 3, _flags, id, _payload),
    do: %{state | streams: Map.delete(state.streams, id)}

  defp handle(state, _type, _flags, _id, _payload), do: state

  defp headers(state, id) do
    {:ok, headers, decode} = HPAX.decode(state.streams[id].hbf, state.decode)
    state = %{state | decode: decode}
    put_in(state.streams[id].headers, headers)
  end

  defp complete(state, id) do
    stream = state.streams[id]
    request = %{headers: Map.new(stream.headers), body: stream.body}
    send(state.test, {:h2_request, self(), id, request})

    case state.handler.(request) do
      :hold -> state
      response -> respond(state, id, response)
    end
  end

  defp respond(state, id, {status, headers, body}) do
    state = settings(state)
    fields = [{":status", Integer.to_string(status)} | headers]
    {hbf, encode} = HPAX.encode(:no_store, fields, state.encode)
    hbf = IO.iodata_to_binary(hbf)
    end_stream = if body == "", do: 1, else: 0
    :ok = :gen_tcp.send(state.socket, frame(1, 4 ||| end_stream, id, hbf))
    if body != "", do: :ok = :gen_tcp.send(state.socket, frame(0, 1, id, body))
    %{state | encode: encode, streams: Map.delete(state.streams, id)}
  end

  defp frame(type, flags, id, payload),
    do: <<byte_size(payload)::24, type::8, flags::8, 0::1, id::31, payload::binary>>
end
