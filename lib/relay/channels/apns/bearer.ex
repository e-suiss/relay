defmodule Relay.Channels.Apns.Bearer do
  @moduledoc """
  The APNs provider token of one connection (CH-25, TN-29): the life cycle of `Relay.Channels.Push.Apns.Token`, signed in the key store, renewed about every 40 minutes and never more often than every 20 on the connection; while the key store cannot sign, the last good token serves for its hour and the alarm fires.
  """

  @behaviour Relay.Channels.Push.H2.Auth

  alias Relay.Channels.Push.Apns.Token

  @impl Relay.Channels.Push.H2.Auth
  def init(config), do: token(config)

  # CH-25
  # TN-29
  @impl Relay.Channels.Push.H2.Auth
  def authorization(config, %Token{} = state, now) do
    state = if state.key_id == config.key_id, do: state, else: token(config)

    case Token.current(state, now) do
      {:ok, jwt, state} -> {:ok, "bearer " <> jwt, state}
      {:degraded, jwt, state, _error} -> {:ok, "bearer " <> jwt, state}
      {:error, error, state} -> {:error, error, state}
    end
  end

  defp token(config) do
    opts =
      case config.refresh_after do
        seconds when is_integer(seconds) and seconds in 1200..3600 -> [refresh_after: seconds]
        _default -> []
      end

    Token.new(config.team_id, config.key_id, config.label, opts)
  end
end
