defmodule Relay.Channels.Push.Tokens do
  @moduledoc """
  The provider tokens of the push adapters that do not hold a connection of their own: the HMS OAuth access token of an app and the VAPID token of a key and push service (TN-30, TN-31). A token is kept in this process's state, never in shared memory, under a key that names the tenant environment, so no tenant reads another's token; it is reused until its expiry and fetched again through the caller's function otherwise.
  """

  use GenServer

  @type key :: term()

  @typedoc "A fetched token and its expiry in Unix seconds."
  @type entry :: %{token: Relay.Redacted.t(), expires_at: integer()}

  @doc "Starts the token holder."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  # TN-30
  # TN-31
  @doc "The token of `key` at Unix time `now`: the held one while it has more than `skew` seconds left, otherwise the one `fetch` returns, which is then held."
  @spec fetch(key(), integer(), non_neg_integer(), (-> {:ok, entry()} | {:error, term()})) ::
          {:ok, Relay.Redacted.t()} | {:error, term()}
  def fetch(key, now, skew, fetch) when is_integer(now) and is_function(fetch, 0) do
    case GenServer.call(__MODULE__, {:get, key, now + skew}) do
      {:ok, token} -> {:ok, token}
      :missing -> fetched(key, fetch.())
    end
  end

  defp fetched(key, {:ok, %{token: token, expires_at: at}}) do
    :ok = GenServer.call(__MODULE__, {:put, key, %{token: token, expires_at: at}})
    {:ok, token}
  end

  defp fetched(_key, {:error, reason}), do: {:error, reason}

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:get, key, until}, _from, state) do
    case Map.get(state, key) do
      %{token: token, expires_at: at} when at > until -> {:reply, {:ok, token}, state}
      _missing_or_due -> {:reply, :missing, state}
    end
  end

  def handle_call({:put, key, entry}, _from, state),
    do: {:reply, :ok, Map.put(prune(state), key, entry)}

  defp prune(state) do
    now = DateTime.to_unix(Relay.Clock.utc_now())
    Map.reject(state, fn {_key, entry} -> entry.expires_at <= now end)
  end
end
