defmodule Relay.Channels.Live.ReportBatcher.Ack do
  @moduledoc """
  The acknowledger of the delivery report batcher (T-41): it tells the receipt job that pushed a batch's receipts how many were written and how many failed.
  """

  @behaviour Broadway.Acknowledger

  @doc false
  @impl Broadway.Acknowledger
  def ack({pid, ref}, successful, failed) do
    send(pid, {ref, length(successful), length(failed)})
    :ok
  end
end
