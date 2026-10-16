defmodule RelayTest.DeliveryFixture do
  @moduledoc "An accepted notification with one sendable delivery, for delivery data layer tests."

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Ingest, Relay.Delivery, RelayTest.TenantFixture],
    exports: []

  alias RelayTest.TenantFixture

  @doc "Creates a tenant, a recipient and an accepted notification with one delivery to send."
  @spec sendable!() :: %{scope: Relay.Scope.t(), keys: map(), delivery_id: Relay.Id.t()}
  def sendable! do
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    recipient = TenantFixture.recipient!(tenant.live, keys)
    delivery = TenantFixture.delivery()

    {:ok, _} =
      Relay.Ingest.accept(
        tenant.live,
        TenantFixture.accept_request(
          [TenantFixture.notification(recipient, deliveries: [delivery])],
          data_key: keys.data
        )
      )

    %{scope: tenant.live, keys: keys, delivery_id: delivery.id}
  end

  @doc "Opens and starts the next attempt of a delivery and returns its number."
  @spec started_attempt!(Relay.Scope.t(), Relay.Id.t()) :: pos_integer()
  def started_attempt!(scope, delivery_id) do
    {:ok, {:opened, attempt_no}} =
      Relay.Delivery.open_attempt(scope, %{
        id: Relay.Id.generate(),
        delivery_id: delivery_id,
        provider: "mailpit",
        provider_idempotency_key: "pik-" <> TenantFixture.random()
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
end
