defmodule RelayTest.WebhookDestinations do
  @moduledoc "The delivery engine with its real destinations for tests: every destination kind is the module of a running node, reached through a resolver, an HTTP transport and a broker dialer that run in the test process, and a destination's credential is resolved from its registered secret reference as on a running node. Jobs, limits and e-mails stay with `RelayTest.WebhookEngine.Runtime`. Nothing leaves the node."

  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Assertions

  alias Relay.Repo
  alias Relay.Webhooks.EngineStore
  alias RelayTest.DestinationFixture
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.ScriptedSocket
  alias RelayTest.TenantFixture

  defmodule Runtime do
    @moduledoc "The test runtime of `RelayTest.WebhookEngine` with the credentials of a running node."

    @behaviour Relay.Webhooks

    alias RelayTest.WebhookEngine.Runtime, as: Fake

    @impl Relay.Webhooks
    defdelegate enqueue(job), to: Fake

    @impl Relay.Webhooks
    defdelegate cancel(message_id), to: Fake

    @impl Relay.Webhooks
    defdelegate with_slot(scope, endpoint_id, limit, holder, fun), to: Fake

    @impl Relay.Webhooks
    defdelegate rate(scope, endpoint_id, per_second), to: Fake

    @impl Relay.Webhooks
    defdelegate event_source(scope, event_id, occurred_at), to: Fake

    @impl Relay.Webhooks
    defdelegate mail(scope, addresses, mail), to: Fake

    @impl Relay.Webhooks
    def credential(scope, ref_id), do: Relay.Webhooks.Live.credential(scope, ref_id)
  end

  @doc "Makes the engine use its real destinations over the test resolver, transport and dialer until the test ends; `extra` is merged into the configuration, such as `extra_ports: [9093]`. Returns the previous configuration."
  @spec install(keyword()) :: keyword()
  def install(extra \\ []) do
    previous = Application.get_env(:relay, Relay.Webhooks, [])

    options = [
      transport: DestinationFixture.Transport,
      resolver: DestinationFixture.Resolver,
      dialer: ScriptedSocket
    ]

    config = [
      runtime: Runtime,
      destinations: %{},
      destination_options: options,
      resolver: DestinationFixture.Resolver
    ]

    merged = previous |> Keyword.merge(config) |> Keyword.merge(extra)
    Application.put_env(:relay, Relay.Webhooks, merged)
    previous
  end

  @doc "Registers `secret` as a destination credential of `scope` behind an environment variable; returns the identifier a destination names and the variable."
  @spec credential!(Relay.Scope.t(), String.t()) :: %{id: String.t(), var: String.t()}
  def credential!(scope, secret) do
    var = "RELAY_TEST_WEBHOOK_" <> String.upcase(TenantFixture.random())
    System.put_env(var, secret)

    {:ok, ref} =
      Relay.Secrets.register_ref(
        scope,
        :webhook_destination,
        "${" <> var <> "}",
        1,
        TenantFixture.digest(),
        TenantFixture.actor()
      )

    %{id: Relay.ExternalId.encode("sec", ref.id), var: var}
  end

  @doc "Creates an endpoint of use `relay_events` for `notification.delivered` with `destination` through the API."
  @spec endpoint!(map(), map()) :: map()
  def endpoint!(ctx, destination) do
    body = %{
      "use" => "relay_events",
      "destination" => destination,
      "event_types" => ["notification.delivered"]
    }

    created = F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body), 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  @doc "Dispatches a new `notification.delivered` outbox event in the scope and returns it."
  @spec dispatch!(map()) :: map()
  def dispatch!(ctx) do
    event = %{
      id: Relay.Id.generate(),
      created_at: Relay.Clock.utc_now(),
      event_type: "notification.delivered",
      stream_key: "notification:" <> uuid(),
      epoch: 1,
      seq: 1,
      payload: %{
        "notification_id" => uuid(),
        "delivery_id" => uuid(),
        "recipient_id" => uuid(),
        "recipient_kind" => "subscriber",
        "workflow" => %{"key" => "welcome", "version" => 1},
        "channel" => "email",
        "delivered_at" => "2026-11-16T10:00:00Z"
      },
      traceparent: nil
    }

    work = fn _status -> Relay.Webhooks.Live.outbox_jobs(event) end
    {:ok, []} = Repo.in_scope(ctx.scope, work)
    event
  end

  defp uuid, do: Relay.Id.to_string(Relay.Id.generate())

  @doc "Runs `fun` in a transaction of the scope and returns its value."
  @spec read(map(), (-> term())) :: term()
  def read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  @doc "The message of `event` on `endpoint`."
  @spec message(map(), map(), map()) :: map() | nil
  def message(ctx, endpoint, event),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, event.id) end)

  @doc "Dispatches an event and returns it with its message on `endpoint`."
  @spec message!(map(), map()) :: {map(), map()}
  def message!(ctx, endpoint) do
    event = dispatch!(ctx)
    assert %{"state" => "pending"} = message = message(ctx, endpoint, event)
    {event, message}
  end

  @doc "The attempt log rows of a message, oldest first."
  @spec attempts(map(), map()) :: [map()]
  def attempts(ctx, message) do
    sql = """
    SELECT a.attempt_no, a.trigger_kind, a.result, a.failure_code, a.response_status,
      a.signature, host(a.destination_ip) AS ip, a.destination_ref, a.body_digest, a.response_ct
    FROM relay.webhook_attempts a WHERE a.message_id = $1 ORDER BY a.attempt_no
    """

    read(ctx, fn ->
      %{rows: rows, columns: columns} = Repo.scoped_query!(sql, [message["id"]])
      Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
    end)
  end

  @doc "Makes one attempt of a message."
  @spec attempt(map(), map(), keyword()) :: term()
  def attempt(ctx, message, opts \\ []) do
    {:ok, result} = Relay.Webhooks.attempt(ctx.scope, message["id"], opts)
    result
  end

  @doc "The jobs the engine queued in the test process since the last call."
  @spec jobs([map()]) :: [map()]
  def jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The requests the test transport sent since the last call, oldest first."
  @spec sent([{map(), map()}]) :: [{map(), map()}]
  def sent(acc \\ []) do
    receive do
      {:sent, connection, request} -> sent([{connection, request} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "A clock that runs `seconds` ahead."
  @spec at(integer()) :: (-> DateTime.t())
  def at(seconds), do: fn -> DateTime.add(Relay.Clock.utc_now(), seconds, :second) end
end
