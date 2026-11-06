defmodule RelayTest.PushFixture do
  @moduledoc "Requests and push policies for the push adapter tests, built from the bundled `push_priority_map` without a database."

  use Boundary, top_level?: true, deps: [Relay, Relay.Channels], exports: []

  @doc "The bundled priority table as a snapshot."
  @spec table() :: struct()
  def table do
    content =
      [:code.priv_dir(:relay), "datasets", "push_priority_map", "v1.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    Relay.Channels.push_priority(content, Relay.Id.generate())
  end

  @doc "The push policy of a delivery with `facts` over the defaults."
  @spec policy(map()) :: map()
  def policy(facts \\ %{}) do
    defaults = %{
      tenant_id: Relay.Id.generate(),
      delivery_id: Relay.Id.to_string(Relay.Id.generate()),
      message_class: "transactional",
      priority: "normal",
      region: "eu",
      locale: "en",
      expires_at: DateTime.add(~U[2026-11-05 00:00:00Z], 3_600, :second),
      now: ~U[2026-11-05 00:00:00Z]
    }

    {:ok, policy} = Relay.Channels.push_policy(table(), Map.merge(defaults, facts))
    policy
  end

  @doc "A provider request to a device on `provider` with `fields` over the defaults."
  @spec request(String.t(), map()) :: struct()
  def request(provider, fields \\ %{}) do
    tenant = Relay.Id.generate()
    delivery = Relay.Id.generate()

    defaults = %{
      scope: Relay.Scope.new!(tenant, :live),
      delivery_id: delivery,
      attempt_no: 1,
      channel: if(provider == "web_push", do: "web_push", else: "push"),
      provider: provider,
      idempotency_key: "dlv-" <> Relay.Id.to_string(delivery),
      target: %{kind: :device, id: Relay.Id.generate(), value: Relay.Redacted.wrap("token")},
      timeout_ms: 5_000,
      content: %{"title" => "Order shipped", "body" => "Your order is on its way."},
      message_class: "transactional",
      push: policy(%{delivery_id: Relay.Id.to_string(delivery)})
    }

    Relay.Channels.request(Map.merge(defaults, fields))
  end
end
