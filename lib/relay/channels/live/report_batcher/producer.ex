defmodule Relay.Channels.Live.ReportBatcher.Producer do
  @moduledoc """
  The producer of the delivery report batcher (T-41). It produces nothing on demand: receipt jobs push their receipts into the pipeline (`Broadway.push_messages/2`), and the job queue keeps them durable.
  """

  use GenStage

  @behaviour Broadway.Producer

  @doc false
  @impl GenStage
  def init(_opts), do: {:producer, :ok}

  @doc false
  @impl GenStage
  def handle_demand(_demand, state), do: {:noreply, [], state}
end
