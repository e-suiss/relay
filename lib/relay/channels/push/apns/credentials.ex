defmodule Relay.Channels.Push.Apns.Credentials do
  @moduledoc """
  The APNs token keys of one Apple team and their zero-downtime rotation with two keys (TN-29): a new key is added on standby next to the active one, traffic moves to it with `promote/2`, delivery is verified, and the old key is retired with `retire/2`. The active key signs every new provider token; a standby key keeps its token state so a rollback is one `promote/2` away. Credentials change hot: the connections of a key are rebuilt, the process is not restarted.
  """

  alias Relay.Channels.Push.Apns.Token
  alias Relay.Error

  @enforce_keys [:team_id, :active, :tokens]
  defstruct [:team_id, :active, :tokens]

  @type t :: %__MODULE__{
          team_id: String.t(),
          active: String.t(),
          tokens: %{String.t() => Token.t()}
        }

  # TN-29
  @doc "Credentials of `team_id` with one active key `key_id` stored under `label`."
  @spec new(String.t(), String.t(), Relay.Keys.label(), keyword()) :: t()
  def new(team_id, key_id, label, opts \\ []) do
    token = Token.new(team_id, key_id, label, opts)
    %__MODULE__{team_id: team_id, active: key_id, tokens: %{key_id => token}}
  end

  # TN-29
  @doc "Adds a standby key next to the active one."
  @spec add_standby(t(), String.t(), Relay.Keys.label(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def add_standby(%__MODULE__{} = c, key_id, label, opts \\ []) do
    if Map.has_key?(c.tokens, key_id) do
      {:error, Error.new(:apns_key_exists, "the key is already loaded")}
    else
      {:ok, put(c, Token.new(c.team_id, key_id, label, opts))}
    end
  end

  # TN-29
  @doc "Makes a loaded key the active one; the previous active key stays on standby."
  @spec promote(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def promote(%__MODULE__{} = c, key_id) do
    if Map.has_key?(c.tokens, key_id),
      do: {:ok, %{c | active: key_id}},
      else: {:error, Error.new(:apns_key_unknown, "the key is not loaded")}
  end

  # TN-29
  @doc "Retires a standby key; the active key cannot be retired."
  @spec retire(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def retire(%__MODULE__{active: key_id}, key_id),
    do: {:error, Error.new(:apns_key_active, "the active key cannot be retired")}

  def retire(%__MODULE__{} = c, key_id) do
    if Map.has_key?(c.tokens, key_id),
      do: {:ok, %{c | tokens: Map.delete(c.tokens, key_id)}},
      else: {:error, Error.new(:apns_key_unknown, "the key is not loaded")}
  end

  # CH-25
  # TN-29
  @doc "The provider token of the active key at `now` (see `Relay.Channels.Push.Apns.Token.current/3`), with the key identifier and the updated credentials."
  @spec token(t(), integer(), keyword()) ::
          {:ok | :degraded, String.t(), String.t(), t()} | {:error, Error.t(), t()}
  def token(%__MODULE__{} = c, now, opts \\ []) do
    state = Map.fetch!(c.tokens, c.active)

    case Token.current(state, now, opts) do
      {:ok, jwt, state} -> {:ok, c.active, jwt, put(c, state)}
      {:degraded, jwt, state, _error} -> {:degraded, c.active, jwt, put(c, state)}
      {:error, error, state} -> {:error, error, put(c, state)}
    end
  end

  defp put(c, %Token{key_id: key_id} = state), do: %{c | tokens: Map.put(c.tokens, key_id, state)}
end
