parameters =
  [:code.priv_dir(:relay), "datasets", "channel_parameters", "v1.json"]
  |> Path.join()
  |> File.read!()
  |> Jason.decode!()
  |> Relay.ChannelParameters.new(Relay.Id.generate())

provider = fn -> "bench" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) end

target = fn name ->
  %{tenant_id: Relay.Id.generate(), environment: :live, channel: "slack", provider: name}
end

call = fn t, outcome, now ->
  case Relay.Channels.check_breaker(parameters, t, now) do
    {decision, ticket} when decision in [:allow, :probe] ->
      Relay.Channels.record_breaker(ticket, outcome, nil, now)
      decision

    {rejected, _ticket} ->
      rejected
  end
end

storm = fn t, outcome ->
  Enum.reduce_while(1..10_000, 0, fn i, _ ->
    case call.(t, outcome, i) do
      {:reject, :breaker_open, _, _} -> {:halt, i}
      _ -> {:cont, i}
    end
  end)
end

closed = target.(provider.())
open = target.(provider.())
storm.(open, {:failure, :transient, :timeout})

tenants = for _ <- 1..1_000, do: target.(provider.())

IO.puts(
  "calls until the provider breaker opens: #{storm.(target.(provider.()), {:failure, :transient, :timeout})}"
)

IO.puts(
  "calls until a tenant breaker opens: #{storm.(target.(provider.()), {:failure, :auth, nil})}"
)

Benchee.run(
  %{
    "breaker.closed_success" => fn -> call.(closed, :success, 1) end,
    "breaker.open_reject" => fn -> call.(open, :success, 2) end,
    "breaker.open_transition" => fn ->
      storm.(target.(provider.()), {:failure, :transient, :timeout})
    end,
    "breaker.tenant_isolation" => fn ->
      Enum.each(tenants, &call.(&1, {:failure, :auth, nil}, 3))
    end
  },
  time: 5,
  memory_time: 1,
  warmup: 2,
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
)
