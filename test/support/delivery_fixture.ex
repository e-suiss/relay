defmodule RelayTest.DeliveryFixture do
  @moduledoc "An accepted notification with one sendable delivery, for delivery data layer tests."

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Ingest, Relay.Delivery, RelayTest.TenantFixture],
    exports: []

  alias RelayTest.TenantFixture

  @doc """
  Creates a tenant, a recipient and an accepted notification with one delivery to send. `:notification` and `:delivery` hold attributes merged into the notification and the delivery, such as `expires_at` or `provider`.
  """
  @spec sendable!(keyword()) :: %{
          scope: Relay.Scope.t(),
          keys: map(),
          delivery_id: Relay.Id.t(),
          notification_id: Relay.Id.t()
        }
  def sendable!(opts \\ []) do
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    recipient = TenantFixture.recipient!(tenant.live, keys)
    delivery = Map.merge(TenantFixture.delivery(), Map.new(Keyword.get(opts, :delivery, [])))

    notification =
      recipient
      |> TenantFixture.notification(deliveries: [delivery])
      |> Map.merge(Map.new(Keyword.get(opts, :notification, [])))

    {:ok, _} =
      Relay.Ingest.accept(
        tenant.live,
        TenantFixture.accept_request([notification], data_key: keys.data)
      )

    %{scope: tenant.live, keys: keys, delivery_id: delivery.id, notification_id: notification.id}
  end

  @doc "Opens and starts the next attempt of a delivery and returns its number; `key` is its provider idempotency key."
  @spec started_attempt!(Relay.Scope.t(), Relay.Id.t(), String.t() | nil) :: pos_integer()
  def started_attempt!(scope, delivery_id, key \\ nil) do
    {:ok, {:opened, attempt_no}} =
      Relay.Delivery.open_attempt(scope, %{
        id: Relay.Id.generate(),
        delivery_id: delivery_id,
        provider: "mailpit",
        provider_idempotency_key: key || "pik-" <> TenantFixture.random()
      })

    {:ok, :started} = Relay.Delivery.start_attempt(scope, delivery_id, attempt_no)
    attempt_no
  end

  @doc "Finishes an attempt."
  @spec finish(Relay.Scope.t(), Relay.Id.t(), pos_integer(), atom(), keyword()) :: term()
  def finish(scope, delivery_id, attempt_no, state, opts \\ []) do
    {:ok, result} =
      Relay.Delivery.finish_attempt(scope, %{
        delivery_id: delivery_id,
        attempt_no: attempt_no,
        state: state,
        failure_class: Keyword.get(opts, :failure_class),
        raw_code: Keyword.get(opts, :raw_code),
        provider_message_id: Keyword.get(opts, :provider_message_id),
        event_id: Relay.Id.generate(),
        occurred_at: Relay.Clock.utc_now(),
        delivery_rank: Keyword.get(opts, :delivery_rank),
        traceparent: nil
      })

    result
  end

  @doc "The attributes of `Relay.Delivery.fail_attempt/2` for a failed attempt; `overrides` replace any of them."
  @spec failure(Relay.Id.t(), pos_integer(), Relay.ChannelParameters.t(), keyword()) :: map()
  def failure(delivery_id, attempt_no, parameters, overrides \\ []) do
    Map.merge(
      %{
        delivery_id: delivery_id,
        attempt_no: attempt_no,
        state: :failed,
        failure_class: "transient",
        condition: "rate_limited",
        raw_code: "429",
        provider_message_id: nil,
        event_id: Relay.Id.generate(),
        occurred_at: Relay.Clock.utc_now(),
        delivery_rank: nil,
        traceparent: nil,
        channel: "email",
        provider: "mailpit",
        message_class: "transactional",
        retry_after_ms: nil,
        expires_at: nil,
        parameters: parameters,
        budget: :allow,
        job: &retry_job(delivery_id, &1)
      },
      Map.new(overrides)
    )
  end

  @doc "The retry job changeset the failure attributes build: a `RelayTest.TenantFixture.SendWorker` job at the planned time and priority."
  @spec retry_job(Relay.Id.t(), map()) :: Ecto.Changeset.t()
  def retry_job(delivery_id, %{at: at, priority: priority, attempt_no: n} = plan) do
    RelayTest.TenantFixture.SendWorker.new(
      %{
        "delivery_id" => Relay.Id.to_string(delivery_id),
        "attempt_no" => n,
        "provider_idempotency_key" => plan[:provider_idempotency_key]
      },
      scheduled_at: at,
      priority: priority
    )
  end

  @doc "The `channel_parameters` snapshot of a bundled version."
  @spec parameters(pos_integer()) :: Relay.ChannelParameters.t()
  def parameters(no \\ 1) do
    [:code.priv_dir(:relay), "datasets", "channel_parameters", "v#{no}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Relay.ChannelParameters.new(Relay.Id.generate())
  end
end
