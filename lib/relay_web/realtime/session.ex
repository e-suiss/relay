defmodule RelayWeb.Realtime.Session do
  @moduledoc """
  One realtime connection's life in the process that serves it, the same for the WebSocket channel and the SSE response (IN-23). `open/3` subscribes to the authorization topics, arms the token expiry, joins the subscriber's connection set (IN-52) and opens the feed (`Relay.Realtime.Feed`). The serving process passes every message it receives to `handle/2`, which answers with envelopes to send, a reason to close, or `:unknown`.

    * A feed signal, or a re-read tick of the signal hub, reads the changes after the cursor from the source (IN-24); a failed read is tried again after a jittered delay, the cursor stays.
    * A signal on an authorization topic checks the token again (IN-33): a refused token closes the connection with the refusal's code. While Valkey is unavailable the hub's re-read ticks check it at most once per the contract's re-authorization interval.
    * The token's expiry closes the connection with `auth_expired_token` unless `refresh/2` replaced the token first (INV-42).
    * Every heartbeat refreshes the connection's entry; an entry pushed out by newer connections of the subscriber closes the connection with `connection_limit` (IN-52).
  """

  alias Relay.Realtime.Connections
  alias Relay.Realtime.Envelope
  alias Relay.Realtime.Feed
  alias RelayWeb.Realtime.Authorization

  @reauthorize_ms Relay.Limits.fetch!(["realtime", "reauthorize_interval_seconds"]) * 1_000
  @overloaded 1013
  @policy 1008

  @enforce_keys [:grant, :token, :feed]
  defstruct [
    :grant,
    :token,
    :feed,
    :member,
    :expiry,
    auth_topics: [],
    checked_ms: 0
  ]

  @type t :: %__MODULE__{
          grant: Authorization.grant(),
          token: String.t(),
          feed: Feed.t(),
          member: String.t() | nil,
          expiry: reference() | nil,
          auth_topics: [String.t()],
          checked_ms: integer()
        }
  @type result :: {:ok, t(), [Envelope.t()]} | {:close, String.t(), t()} | :unknown

  # IN-23
  # IN-33
  # IN-52
  @doc "Opens a connection's session for a grant; `:cursor` resumes the stream, `:device_id` names the device in the connection set, `register: false` keeps the connection out of the set (long-poll)."
  @spec open(Authorization.grant(), String.t(), keyword()) ::
          {:ok, t(), [Envelope.t()]} | {:error, Relay.Error.t()}
  def open(grant, token, opts) do
    topics = Authorization.topics(grant.scope)
    Enum.each(topics, &Relay.Platform.subscribe_signal/1)
    source = Keyword.get_lazy(opts, :source, &Relay.Realtime.source/0)

    case Feed.open(grant.scope, grant.subscriber_id, Keyword.get(opts, :cursor), source) do
      {:ok, feed, envelopes} ->
        session = %__MODULE__{
          grant: grant,
          token: token,
          feed: feed,
          auth_topics: topics,
          checked_ms: Relay.Clock.monotonic_ms()
        }

        session = session |> arm_expiry() |> register(opts)
        {:ok, session, envelopes}

      {:error, _reason} ->
        Enum.each(topics, &Relay.Platform.unsubscribe_signal/1)
        {:error, Relay.Error.new(:service_unavailable, "the stream cannot be read now")}
    end
  end

  # IN-24
  # IN-33
  # IN-52
  @doc "Handles one message of the serving process."
  @spec handle(t(), term()) :: result()
  def handle(%__MODULE__{} = session, {:relay_signal, topic, event}) do
    cond do
      Feed.signal?(session.feed, topic) -> catch_up(session)
      topic in session.auth_topics -> reauthorize(session, refreshed(topic, event))
      true -> :unknown
    end
  end

  def handle(session, {:relay_realtime, :retry}), do: catch_up(session)

  def handle(%__MODULE__{expiry: ref} = session, {:relay_realtime, :expired, ref}),
    do: {:close, "auth_expired_token", session}

  def handle(session, {:relay_realtime, :expired, _stale}), do: {:ok, session, []}

  def handle(session, {:relay_realtime, :heartbeat}), do: heartbeat(session)
  def handle(_session, _message), do: :unknown

  # INV-42
  # IN-33
  @doc "Replaces the connection's token with a fresh one for the same subscriber in the same scope, which moves the expiry."
  @spec refresh(t(), String.t()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def refresh(%__MODULE__{} = session, token) do
    with {:ok, grant} <- Authorization.authorize(token),
         true <- Authorization.same_subject?(grant, session.grant) do
      checked = Relay.Clock.monotonic_ms()
      {:ok, arm_expiry(%{session | grant: grant, token: token, checked_ms: checked})}
    else
      false -> {:error, Relay.Error.new(:auth_invalid_token, "another subscriber's token")}
      {:error, _} = error -> error
    end
  end

  @doc "Ends the session: leaves the connection set and drops the subscriptions."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = session) do
    :ok = Feed.close(session.feed)
    Enum.each(session.auth_topics, &Relay.Platform.unsubscribe_signal/1)

    if session.member,
      do: Connections.leave(session.grant.scope, session.grant.subscriber_id, session.member)

    :ok
  end

  # IN-52
  @doc "The WebSocket close code of a close reason: `1013` for an overloaded node, `1008` otherwise."
  @spec close_code(String.t()) :: 1008 | 1013
  def close_code("overloaded"), do: @overloaded
  def close_code(_reason), do: @policy

  defp catch_up(session) do
    case Feed.catch_up(session.feed) do
      {:ok, feed, envelopes} ->
        {:ok, %{session | feed: feed}, envelopes}

      {:error, _reason} ->
        retry_ms = Relay.Realtime.Admission.retry_after() * 1_000
        Process.send_after(self(), {:relay_realtime, :retry}, retry_ms)
        {:ok, session, []}
    end
  end

  defp refreshed(topic, event) do
    :ok = Authorization.refresh_keys(topic)
    event
  end

  defp reauthorize(session, :poll) do
    if Relay.Clock.monotonic_ms() - session.checked_ms >= @reauthorize_ms,
      do: reauthorize(session, :changed),
      else: {:ok, session, []}
  end

  defp reauthorize(session, _event) do
    session = %{session | checked_ms: Relay.Clock.monotonic_ms()}

    case Authorization.authorize(session.token) do
      {:ok, grant} ->
        {:ok, %{session | grant: grant}, []}

      {:error, %Relay.Error{code: :service_unavailable}} ->
        {:ok, session, []}

      {:error, %Relay.Error{code: code}} ->
        {:close, Atom.to_string(code), session}
    end
  end

  defp heartbeat(%__MODULE__{member: nil} = session), do: {:ok, session, []}

  defp heartbeat(session) do
    Process.send_after(self(), {:relay_realtime, :heartbeat}, Connections.heartbeat_ms())

    case Connections.touch(session.grant.scope, session.grant.subscriber_id, session.member) do
      :gone -> {:close, "connection_limit", session}
      _ok_or_error -> {:ok, session, []}
    end
  end

  defp arm_expiry(session) do
    now_s = DateTime.to_unix(Relay.Clock.utc_now())
    ref = make_ref()
    after_ms = max(session.grant.expires_at - now_s, 0) * 1_000
    Process.send_after(self(), {:relay_realtime, :expired, ref}, after_ms)
    %{session | expiry: ref}
  end

  defp register(session, opts) do
    if Keyword.get(opts, :register, true),
      do: join(session, Keyword.get(opts, :device_id)),
      else: session
  end

  defp join(%__MODULE__{grant: grant} = session, device_id) do
    case Connections.join(grant.scope, grant.subscriber_id, device_id) do
      {:ok, member, _evicted} ->
        Process.send_after(self(), {:relay_realtime, :heartbeat}, Connections.heartbeat_ms())
        %{session | member: member}

      {:error, _} ->
        session
    end
  end
end
