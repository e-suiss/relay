defmodule Relay.Channels.Push.Apns.Token do
  @moduledoc """
  The life cycle of one APNs provider token (CH-25, TN-29): an ES256 JWT with the `kid` of the `.p8` key and the team as `iss`, signed in the key store, where the key was imported and never leaves (TN-28). A token is renewed about every 40 minutes (configurable between 20 and 60), never sooner than 20 minutes after the previous one, since APNs answers more frequent updates with `TooManyProviderTokenUpdates`, and it is never used once it is an hour old.

  The last good token stays cached. When the key store cannot sign, the last good token keeps serving while it is younger than an hour and the alarm hook fires at once; the outage has that much runway. Each connection uses the token of the state it reads, so the 20-minute floor holds per connection too.

  The state is a value: the adapter keeps it per `{team, key}` and passes `now` in Unix seconds.
  """

  alias Relay.Channels.Push.Jwt
  alias Relay.Error

  @min_age 20 * 60
  @max_age 60 * 60
  @default_refresh 40 * 60

  @enforce_keys [:team_id, :key_id, :label]
  defstruct [:team_id, :key_id, :label, :token, :issued_at, refresh_after: @default_refresh]

  @type t :: %__MODULE__{
          team_id: String.t(),
          key_id: String.t(),
          label: Relay.Keys.label(),
          token: String.t() | nil,
          issued_at: integer() | nil,
          refresh_after: pos_integer()
        }

  @typedoc "Called once per failed signing with the error, the team and the key identifier."
  @type alarm :: (Error.t(), String.t(), String.t() -> any())

  @type result ::
          {:ok, String.t(), t()}
          | {:degraded, String.t(), t(), Error.t()}
          | {:error, Error.t(), t()}

  # CH-25
  # TN-29
  @doc "A state without a token for the key `key_id` of `team_id`, stored in the key store under `label`; `:refresh_after` (seconds, 1200 to 3600) sets the renewal age."
  @spec new(String.t(), String.t(), Relay.Keys.label(), keyword()) :: t()
  def new(team_id, key_id, label, opts \\ [])
      when is_binary(team_id) and is_binary(key_id) and is_binary(label) do
    case Keyword.get(opts, :refresh_after, @default_refresh) do
      refresh when is_integer(refresh) and refresh >= @min_age and refresh <= @max_age ->
        %__MODULE__{team_id: team_id, key_id: key_id, label: label, refresh_after: refresh}

      _other ->
        raise ArgumentError, "refresh_after is between #{@min_age} and #{@max_age} seconds"
    end
  end

  # CH-25
  # TN-29
  @doc """
  The token to send with at `now`. A token younger than the renewal age is reused; an older one is renewed. When signing fails, a token younger than an hour is returned as `:degraded` and `opts[:alarm]` is called; without one the result is an error. `opts` takes `:signer` (`Relay.Keys.sign/3`) and `:alarm` (a telemetry event `[:relay, :push, :signing_unavailable]` by default).
  """
  @spec current(t(), integer(), keyword()) :: result()
  def current(%__MODULE__{} = state, now, opts \\ []) when is_integer(now) do
    case age(state, now) do
      age when is_integer(age) and age < state.refresh_after -> {:ok, state.token, state}
      _due -> renew(state, now, opts)
    end
  end

  # CH-25
  # TN-29
  @doc "Renews before the renewal age, after APNs answered `ExpiredProviderToken`; refused while the token is younger than 20 minutes."
  @spec refresh(t(), integer(), keyword()) :: result()
  def refresh(%__MODULE__{} = state, now, opts \\ []) when is_integer(now) do
    case age(state, now) do
      age when is_integer(age) and age < @min_age ->
        {:error, too_soon(), state}

      _due ->
        renew(state, now, opts)
    end
  end

  # TN-29
  @doc "Whether the state holds a token APNs still accepts at `now`."
  @spec valid?(t(), integer()) :: boolean()
  def valid?(%__MODULE__{} = state, now) do
    case age(state, now) do
      age when is_integer(age) -> age >= 0 and age < @max_age
      nil -> false
    end
  end

  defp age(%__MODULE__{token: token, issued_at: issued_at}, now)
       when is_binary(token) and is_integer(issued_at),
       do: now - issued_at

  defp age(_state, _now), do: nil

  defp renew(state, now, opts) do
    signer = Keyword.get(opts, :signer, &Relay.Keys.sign/3)
    header = [{"kid", state.key_id}]
    claims = [{"iss", state.team_id}, {"iat", now}]

    case Jwt.sign(:es256, state.label, header, claims, signer) do
      {:ok, token} ->
        {:ok, token, %{state | token: token, issued_at: now}}

      {:error, error} ->
        alarm(opts, error, state)
        fallback(state, now, error)
    end
  end

  defp fallback(state, now, error) do
    if valid?(state, now),
      do: {:degraded, state.token, state, error},
      else: {:error, unavailable(error), state}
  end

  defp too_soon,
    do: Error.new(:apns_token_refresh_too_soon, "the provider token is younger than 20 minutes")

  defp unavailable(error),
    do: Error.new(:apns_token_unavailable, "no valid provider token", %{cause: error.code})

  defp alarm(opts, error, state) do
    case Keyword.get(opts, :alarm) do
      fun when is_function(fun, 3) ->
        fun.(error, state.team_id, state.key_id)

      nil ->
        :telemetry.execute([:relay, :push, :signing_unavailable], %{count: 1}, %{
          provider: :apns,
          team_id: state.team_id,
          key_id: state.key_id,
          code: error.code
        })
    end
  end
end
