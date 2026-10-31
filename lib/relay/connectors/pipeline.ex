defmodule Relay.Connectors.Pipeline do
  @moduledoc """
  The Broadway pipeline of one ingest connector (T-41): the source's producer and `concurrency` processors, without batchers. Each processor accepts one message at a time through `Relay.Connectors.Intake`; a message is acknowledged to its source only after its event is durably accepted (INV-2), and failed with its error code when it can never be accepted, so the source applies its own failure handling (the outbox records the code, a queue redelivers or dead-letters it).

  Back-pressure is the demand of the processors: a message that must be tried again keeps its processor until it is accepted or rejected, waiting at most `max_wait_ms` between attempts, so a rate-limited, overloaded or held connector stops pulling from its source instead of buffering. Broadway's own rate limiting is not used (T-41). Every attempt emits `[:relay, :connector, :message]` with the connector name, the result and the error code; message contents are never logged.
  """

  use Broadway

  require Logger

  alias Broadway.Message
  alias Relay.Connectors.Connector
  alias Relay.Connectors.Intake

  @log_every 60

  @doc "Starts the pipeline of a connector under its registered name."
  @spec start_link(Connector.t()) :: GenServer.on_start()
  def start_link(%Connector{} = connector) do
    Broadway.start_link(__MODULE__,
      name: Connector.process_name(connector),
      context: connector,
      producer: [module: connector.producer, concurrency: 1],
      processors: [default: [concurrency: connector.concurrency]]
    )
  end

  # T-41
  # INV-2
  @impl Broadway
  def handle_message(_processor, %Message{data: data} = message, %Connector{} = connector) do
    Logger.metadata(connector: connector.name)

    case deliver(connector, data, 1) do
      :ok -> message
      {:error, %Relay.Error{code: code}} -> Message.failed(message, Atom.to_string(code))
    end
  end

  defp deliver(connector, data, attempt) do
    case try_once(connector, data) do
      {:accepted, _kind} ->
        emit(connector, :accepted, nil)
        :ok

      {:rejected, error} ->
        emit(connector, :rejected, error.code)
        Logger.warning("connector message rejected", code: error.code)
        {:error, error}

      {:retry, wait_ms, error} ->
        emit(connector, :retry, error.code)

        if rem(attempt - 1, @log_every) == 0,
          do: Logger.warning("connector message waits", code: error.code, attempt: attempt)

        Process.sleep(min(wait_ms, connector.max_wait_ms))
        deliver(connector, data, attempt + 1)
    end
  end

  defp try_once(connector, data) do
    Intake.run(connector, data)
  rescue
    exception ->
      Logger.error("connector message failed", reason: inspect(exception.__struct__))
      {:retry, 1000, Relay.Error.new(:service_unavailable, "the message could not be accepted")}
  end

  defp emit(connector, result, code) do
    :telemetry.execute([:relay, :connector, :message], %{count: 1}, %{
      connector: connector.name,
      result: result,
      code: code
    })
  end
end
