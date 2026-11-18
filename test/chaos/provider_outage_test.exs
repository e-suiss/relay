defmodule Relay.Chaos.ProviderOutageTest do
  use ExUnit.Case, async: true

  alias Relay.Channels
  alias Relay.Channels.Breaker
  alias Relay.FaultInjection
  alias Relay.FaultInjection.Record
  alias RelayTest.DeliveryFixture

  defp provider, do: "p" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp outage(provider) do
    %Record{
      id: Relay.Id.generate(),
      scope_kind: :installation,
      target_environment: :live,
      provider: provider,
      kind: :concurrency_exhausted,
      rate_percent: 100,
      status: :active,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    }
  end

  defp call(p, point, records, now, sent) do
    case Channels.check_breaker(p, point, now) do
      {{:reject, :breaker_open, _wait, _rule}, _ticket} ->
        {:rejected, sent}

      {_admitted, ticket} ->
        case FaultInjection.provider_fault(point, records: records, chaos_mode: true) do
          {:fail, kind} ->
            outcome = Channels.fault_outcome(kind)
            failure = {:failure, outcome.failure_class, outcome.condition}
            :ok = Channels.record_breaker(ticket, failure, nil, now)
            {:failed, sent}

          nil ->
            :ok = Channels.record_breaker(ticket, :success, nil, now)
            {:sent, sent + 1}
        end
    end
  end

  test "OP-93: an injected provider outage opens the breaker and later sends go out once each" do
    p = DeliveryFixture.parameters(1)
    name = provider()

    point = %{
      tenant_id: Relay.Id.generate(),
      environment: :live,
      channel: "slack",
      provider: name
    }

    records = [outage(name)]
    now = 1_000_000

    {results, _sent} = Enum.map_reduce(1..40, 0, &call(p, point, records, now + &1, &2))

    assert Breaker.provider_state(name) == :open
    assert :rejected in results
    first_rejected = Enum.find_index(results, &(&1 == :rejected))
    assert Enum.all?(Enum.drop(results, first_rejected), &(&1 == :rejected))

    {{:reject, :breaker_open, wait, _rule}, _} = Channels.check_breaker(p, point, now + 100)
    later = now + 100 + wait

    {outcomes, sent} =
      Enum.map_reduce(1..3, 0, fn i, sent -> call(p, point, [], later + i, sent) end)

    assert outcomes == [:sent, :sent, :sent]
    assert sent == 3
  end
end
