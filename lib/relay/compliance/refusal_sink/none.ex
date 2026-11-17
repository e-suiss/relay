defmodule Relay.Compliance.RefusalSink.None do
  @moduledoc "The refusal sink of an installation without a registry: a refusal notice stays in Relay."

  @behaviour Relay.Compliance.RefusalSink

  @impl Relay.Compliance.RefusalSink
  def refused(_scope, _notice), do: :ok
end
