defmodule Relay.Channels.Registry do
  @moduledoc """
  The registered channel adapters and their activation (CH-2, DS-11, C-44). An adapter is registered by adding its module to `@adapters`; it is activated, and may receive traffic, only when its declaration in the active `channel_event_evidence` version passes `Relay.ChannelDeclarations.gate/2` and declares exactly the adapter's channels. A registered adapter that is not activated is listed with what is missing and receives no traffic. The same check runs in CI over every registered adapter and the declarations in the repository.
  """

  alias Relay.ChannelDeclarations

  @adapters [
    Relay.Channels.Fake,
    Relay.Channels.Smtp,
    Relay.Channels.Apns,
    Relay.Channels.Fcm,
    Relay.Channels.Hms,
    Relay.Channels.WebPush,
    Relay.Channels.UnifiedPush
  ]

  @type missing :: ChannelDeclarations.missing() | :channels
  @type status :: %{
          provider: String.t(),
          adapter: module(),
          channels: [String.t()],
          activated: boolean(),
          missing: [missing()]
        }

  @doc "The registered adapter modules."
  @spec adapters() :: [module(), ...]
  def adapters, do: @adapters

  @doc "The registered adapter of a provider."
  @spec adapter(String.t()) :: {:ok, module()} | {:error, :unknown_provider}
  def adapter(provider) do
    case Enum.find(@adapters, &(&1.provider() == provider)) do
      nil -> {:error, :unknown_provider}
      module -> {:ok, module}
    end
  end

  # CH-2
  # DS-11
  @doc "Checks the activation of a registered adapter against a declarations snapshot."
  @spec check(ChannelDeclarations.t(), module()) :: :ok | {:error, [missing(), ...]}
  def check(%ChannelDeclarations{} = declarations, adapter) do
    provider = adapter.provider()

    case {ChannelDeclarations.gate(declarations, provider), channels?(declarations, adapter)} do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, [:channels]}
      {{:error, missing}, true} -> {:error, missing}
      {{:error, missing}, false} -> {:error, missing ++ [:channels]}
    end
  end

  defp channels?(declarations, adapter) do
    case ChannelDeclarations.declaration(declarations, adapter.provider()) do
      {:ok, declaration} -> Enum.sort(declaration["channels"]) == Enum.sort(adapter.channels())
      {:error, :unknown_provider} -> false
    end
  end

  # CH-2
  @doc "The activated adapter of a provider: `{:error, :not_activated}` for a registered adapter whose declaration does not pass the gate."
  @spec activated(ChannelDeclarations.t(), String.t()) ::
          {:ok, module()} | {:error, :unknown_provider | :not_activated}
  def activated(%ChannelDeclarations{} = declarations, provider) do
    with {:ok, adapter} <- adapter(provider) do
      case check(declarations, adapter) do
        :ok -> {:ok, adapter}
        {:error, _missing} -> {:error, :not_activated}
      end
    end
  end

  # CH-2
  # C-44
  @doc "The status of every registered adapter: its channels, whether it is activated and what its declaration misses."
  @spec status(ChannelDeclarations.t()) :: [status()]
  def status(%ChannelDeclarations{} = declarations) do
    for adapter <- @adapters do
      missing =
        case check(declarations, adapter) do
          :ok -> []
          {:error, missing} -> missing
        end

      %{
        provider: adapter.provider(),
        adapter: adapter,
        channels: adapter.channels(),
        activated: missing == [],
        missing: missing
      }
    end
  end
end
