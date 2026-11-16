defmodule RelayTest.WebhookEngine do
  @moduledoc "The delivery engine's ports for tests: a destination that answers from a script kept by the calling process and a runtime that reports the jobs, cancellations and e-mails it is handed to that process. Nothing leaves the node."

  use Boundary, top_level?: true, deps: [Relay, Relay.Webhooks], exports: [Destination, Runtime]

  @doc "Makes the engine use the test destination and runtime until the test ends; returns the previous configuration."
  @spec install() :: keyword()
  def install do
    previous = Application.get_env(:relay, Relay.Webhooks, [])

    Application.put_env(
      :relay,
      Relay.Webhooks,
      Keyword.merge(previous,
        runtime: __MODULE__.Runtime,
        destinations: %{"https" => __MODULE__.Destination}
      )
    )

    previous
  end

  @doc "Scripts the answers of the next deliveries of the calling process; a delivery beyond the script is answered `200`."
  @spec answers([term()]) :: :ok
  def answers(answers) do
    Process.put({__MODULE__, :answers}, answers)
    :ok
  end

  @doc "An HTTP answer of a destination."
  @spec http(pos_integer(), [{String.t(), String.t()}], binary()) :: {:ok, map()}
  def http(status, headers \\ [], body \\ "") do
    {:ok,
     %{
       kind: :http,
       status: status,
       headers: headers,
       body: body,
       truncated: false,
       duration_ms: 3,
       address: "203.0.114.7"
     }}
  end

  @doc "A failure of a destination."
  @spec failure(atom()) :: {:error, map()}
  def failure(class),
    do: {:error, %{class: class, reason: "scripted", duration_ms: 4, address: "203.0.114.7"}}

  defmodule Destination do
    @moduledoc "A destination that answers from the calling process's script and reports each delivery to it."

    @doc "Answers one delivery from the script."
    @spec deliver(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
    def deliver(config, prepared, opts) do
      send(self(), {:webhook_delivery, config, prepared, opts})

      case Process.get({RelayTest.WebhookEngine, :answers}, []) do
        [answer | rest] ->
          Process.put({RelayTest.WebhookEngine, :answers}, rest)
          answer

        [] ->
          RelayTest.WebhookEngine.http(200)
      end
    end
  end

  defmodule Runtime do
    @moduledoc "A runtime that reports to the calling process and decides limits from its process dictionary (`:webhook_rate`, `:webhook_slot`, `:webhook_source`, `:webhook_mail`)."

    @behaviour Relay.Webhooks

    @impl Relay.Webhooks
    def enqueue(job) do
      send(self(), {:webhook_job, job})
      :ok
    end

    @impl Relay.Webhooks
    def cancel(message_id) do
      send(self(), {:webhook_cancel, message_id})
      :ok
    end

    @impl Relay.Webhooks
    def with_slot(_scope, _endpoint_id, _limit, _holder, fun) do
      case Process.get(:webhook_slot, :free) do
        :free -> {:ok, fun.()}
        {:full, wait_ms} -> {:full, wait_ms}
      end
    end

    @impl Relay.Webhooks
    def rate(_scope, _endpoint_id, _per_second), do: Process.get(:webhook_rate, :allow)

    @impl Relay.Webhooks
    def event_source(_scope, _event_id, _occurred_at), do: Process.get(:webhook_source)

    @impl Relay.Webhooks
    def credential(_scope, _ref_id), do: Process.get(:webhook_credential)

    @impl Relay.Webhooks
    def mail(_scope, addresses, mail) do
      send(self(), {:webhook_mail, addresses, mail})
      Process.get(:webhook_mail, :ok)
    end
  end
end
