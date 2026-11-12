defmodule RelayWeb.Api.RealtimeController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Realtime.Connections
  alias Relay.Realtime.Feed
  alias RelayWeb.Api.Response
  alias RelayWeb.Realtime.Authorization
  alias RelayWeb.Realtime.Session

  @cursor ~r/\A[\x21-\x7e]{1,512}\z/
  @keepalive_ms Relay.Limits.fetch!(["realtime", "keepalive_seconds"]) * 1_000
  @wait_ms Relay.Limits.fetch!(["realtime", "long_poll_wait_seconds"]) * 1_000

  # IN-23
  # IN-33
  # IN-52
  # IN-54
  @spec events(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def events(conn, params) do
    token = Authorization.bearer(conn)
    origin = conn |> get_req_header("origin") |> List.first()

    with :ok <- admitted(),
         {:ok, grant} <- Authorization.authorize(token, origin),
         {:ok, cursor} <- cursor(conn |> get_req_header("last-event-id") |> List.first()),
         {:ok, device_id} <- device(params["device_id"]),
         {:ok, session, envelopes} <-
           Session.open(grant, token, cursor: cursor, device_id: device_id, origin: origin) do
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)
      |> send_events(session, envelopes)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # IN-23
  # IN-24
  @spec poll(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def poll(conn, params) do
    %{scope: scope, principal: principal} = conn.assigns
    source = Relay.Realtime.source()

    with {:ok, cursor} <- cursor(params["cursor"]),
         {:ok, feed, envelopes} <- open(scope, principal.subscriber_id, cursor, source) do
      deadline = Relay.Clock.monotonic_ms() + @wait_ms
      {feed, envelopes} = if envelopes == [], do: wait(feed, deadline), else: {feed, envelopes}
      :ok = Feed.close(feed)
      Response.json(conn, 200, %{"events" => envelopes, "cursor" => feed.cursor})
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp admitted do
    case Relay.Realtime.admit() do
      :ok ->
        :ok

      {:error, retry_after} ->
        {:error,
         Relay.Error.new(:service_unavailable, "too many new connections", %{
           retry_after: retry_after
         })}
    end
  end

  defp open(scope, subscriber_id, cursor, source) do
    case Feed.open(scope, subscriber_id, cursor, source, counters: is_nil(cursor)) do
      {:ok, feed, envelopes} ->
        {:ok, feed, envelopes}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "the stream cannot be read now")}
    end
  end

  defp wait(feed, deadline) do
    remaining = max(deadline - Relay.Clock.monotonic_ms(), 0)

    receive do
      {:relay_signal, topic, _event} -> signalled(feed, topic, deadline)
    after
      remaining -> {feed, []}
    end
  end

  defp signalled(feed, topic, deadline) do
    with true <- Feed.signal?(feed, topic),
         {:ok, feed, [_ | _] = envelopes} <- Feed.catch_up(feed) do
      {feed, envelopes}
    else
      {:ok, feed, []} -> wait(feed, deadline)
      _other -> wait(feed, deadline)
    end
  end

  defp send_events(conn, session, envelopes) do
    case write(conn, envelopes) do
      {:ok, conn} ->
        Process.send_after(self(), :relay_realtime_keepalive, @keepalive_ms)
        loop(conn, session)

      {:error, _reason} ->
        finish(conn, session)
    end
  end

  defp loop(conn, session) do
    receive do
      :relay_realtime_keepalive -> keepalive(conn, session)
      message -> handled(conn, Session.handle(session, message), session)
    end
  end

  defp keepalive(conn, session) do
    case chunk(conn, ": keep-alive\n\n") do
      {:ok, conn} ->
        Process.send_after(self(), :relay_realtime_keepalive, @keepalive_ms)
        loop(conn, session)

      {:error, _reason} ->
        finish(conn, session)
    end
  end

  defp handled(conn, {:ok, session, envelopes}, _before) do
    case write(conn, envelopes) do
      {:ok, conn} -> loop(conn, session)
      {:error, _reason} -> finish(conn, session)
    end
  end

  defp handled(conn, {:close, _reason, session}, _before), do: finish(conn, session)
  defp handled(conn, :unknown, session), do: loop(conn, session)

  defp finish(conn, session) do
    :ok = Session.close(session)
    conn
  end

  defp write(conn, []), do: {:ok, conn}
  defp write(conn, envelopes), do: chunk(conn, Enum.map(envelopes, &event/1))

  defp event(envelope) do
    [
      event_id(envelope),
      "event: ",
      envelope["t"],
      "\ndata: ",
      Jason.encode_to_iodata!(envelope),
      "\n\n"
    ]
  end

  defp event_id(%{"id" => id}) when is_binary(id),
    do: if(Regex.match?(@cursor, id), do: ["id: ", id, "\n"], else: [])

  defp event_id(_envelope), do: []

  defp cursor(nil), do: {:ok, nil}

  defp cursor(cursor) when is_binary(cursor) do
    if Regex.match?(@cursor, cursor),
      do: {:ok, cursor},
      else: {:error, invalid("/cursor", "the cursor is not a stream cursor")}
  end

  defp cursor(_other), do: {:error, invalid("/cursor", "the cursor is not a stream cursor")}

  defp device(nil), do: {:ok, nil}

  defp device(device_id) do
    if Connections.device?(device_id),
      do: {:ok, device_id},
      else: {:error, invalid("/device_id", "device_id is not a device identifier")}
  end

  defp invalid(pointer, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: "invalid_format", detail: detail}]
    })
  end
end
