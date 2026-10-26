defmodule Relay.Platform.Valkey.Redix do
  @moduledoc """
  Valkey adapter over Redix. It supervises a subscriber registry, one command connection, one pub/sub connection and the forwarder that translates pub/sub events into the port's messages. Connections start without blocking and reconnect on their own; an unreachable Valkey never stops the node. Subscriptions live in the registry, so they survive a connection or forwarder restart.
  """

  @behaviour Relay.Platform.Valkey

  use Supervisor

  alias Relay.Platform.Valkey.Redix.Forwarder

  @registry __MODULE__.Subscribers
  @command __MODULE__.Command
  @pubsub __MODULE__.PubSub
  @forwarder Forwarder

  @doc "Starts the adapter's registry and connections."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    url = Keyword.fetch!(opts, :url)

    children = [
      {Registry, keys: :duplicate, name: @registry},
      %{
        id: @command,
        start: {Redix, :start_link, [url, [name: @command, sync_connect: false]]}
      },
      %{
        id: @pubsub,
        start: {Redix.PubSub, :start_link, [url, [name: @pubsub, sync_connect: false]]}
      },
      {Forwarder, name: @forwarder, pubsub: @pubsub, registry: @registry}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)
  end

  @impl Relay.Platform.Valkey
  def command(command), do: Redix.command(@command, command)

  @impl Relay.Platform.Valkey
  def pipeline(commands), do: Redix.pipeline(@command, commands)

  @impl Relay.Platform.Valkey
  def subscribe(channel) do
    if Registry.values(@registry, channel, self()) == [],
      do: {:ok, _} = Registry.register(@registry, channel, nil)

    Forwarder.ensure(@forwarder, channel, self())
  end

  @impl Relay.Platform.Valkey
  def unsubscribe(channel) do
    Registry.unregister(@registry, channel)
    Forwarder.release(@forwarder, channel)
  end
end
