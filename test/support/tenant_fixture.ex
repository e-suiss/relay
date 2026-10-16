defmodule RelayTest.TenantFixture do
  @moduledoc "Tenants, keys and recipients written through the database functions for data layer tests."

  use Boundary, top_level?: true, deps: [Relay, Relay.Tenancy], exports: [SendWorker]

  alias Relay.Repo
  alias Relay.Scope

  @doc "The actor tests write as."
  @spec actor() :: Relay.Actor.t()
  def actor do
    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    actor
  end

  @doc "A random 32-byte digest."
  @spec digest() :: <<_::256>>
  def digest, do: :crypto.strong_rand_bytes(32)

  @doc "Runs the rest of the transaction as `role` when the test connection is a superuser."
  @spec as_role(module(), String.t()) :: :ok
  def as_role(repo \\ Repo, role) do
    %{rows: [[super?]]} =
      repo.query!("SELECT rolsuper FROM pg_roles WHERE rolname = current_user", [])

    if super?, do: repo.query!("SET LOCAL ROLE #{role}", [])
    :ok
  end

  @doc "Returns the installation region."
  @spec region() :: Relay.Region.t()
  def region do
    %{rows: [[region]]} = Repo.query!("SELECT region FROM relay.installation", [])
    {:ok, region} = Relay.Region.cast(region)
    region
  end

  @doc "Creates a tenant and returns its live and test scopes."
  @spec tenant!(keyword()) :: %{id: Relay.Id.t(), attrs: map(), live: Scope.t(), test: Scope.t()}
  def tenant!(opts \\ []) do
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      access_tenant_id: "acc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      region: Keyword.get_lazy(opts, :region, &region/0),
      sector: "general",
      default_timezone: "Europe/Istanbul",
      default_locale: "tr-TR",
      record_digest: digest()
    }

    {:created, ^id} = Relay.Tenancy.create_tenant(attrs, actor())
    %{id: id, attrs: attrs, live: Scope.new!(id, :live), test: Scope.new!(id, :test)}
  end

  @doc "Registers the tenant keys of a scope and returns their identifiers."
  @spec keys!(Scope.t()) :: %{
          data: Relay.Id.t(),
          dek_wrap: Relay.Id.t(),
          blind_index: Relay.Id.t()
        }
  def keys!(scope) do
    data = Relay.Id.generate()
    wrap = Relay.Id.generate()
    bidx = Relay.Id.generate()

    for {id, purpose} <- [{data, :data}, {wrap, :dek_wrap}] do
      {:ok, :created} =
        Relay.Tenancy.register_tenant_key(
          scope,
          %{
            id: id,
            purpose: purpose,
            kek_ref: "pkcs11:object=kek-test?version=1",
            wrapped_key: wrapped(),
            record_digest: digest()
          },
          actor()
        )
    end

    {:ok, :created} =
      Relay.Tenancy.register_blind_index_key(
        scope,
        %{id: bidx, hsm_ref: "pkcs11:object=bidx-test", record_digest: digest()},
        actor()
      )

    %{data: data, dek_wrap: wrap, blind_index: bidx}
  end

  @doc "Creates a recipient in a scope with registered keys."
  @spec recipient!(Scope.t(), map(), keyword()) :: Relay.Id.t()
  def recipient!(scope, keys, opts \\ []) do
    id = Relay.Id.generate()

    {:ok, {:created, ^id}} =
      Relay.Tenancy.create_recipient(scope, %{
        id: id,
        kind: Keyword.get(opts, :kind, :subscriber),
        external_id_bidx: :crypto.strong_rand_bytes(32),
        bidx_key_id: keys.blind_index,
        external_id_ct: wrapped(),
        profile_dek_id: Relay.Id.generate(),
        profile_wrapped_dek: wrapped(),
        wrapping_key_id: keys.dek_wrap
      })

    id
  end

  @doc "A sub-tenant in a scope."
  @spec subtenant!(Scope.t(), Relay.Id.t()) :: Relay.Id.t()
  def subtenant!(scope, id \\ Relay.Id.generate()) do
    {:ok, {result, ^id, _version}} =
      Relay.Tenancy.upsert_subtenant(
        scope,
        %{
          id: id,
          access_organization_id: "org_" <> Base.encode16(id, case: :lower),
          name: "Branch",
          record_digest: digest()
        },
        actor()
      )

    true = result in [:created, :unchanged]
    id
  end

  @doc "Notification attributes for the accept path."
  @spec notification(Relay.Id.t(), keyword()) :: map()
  def notification(recipient_id, opts \\ []) do
    %{
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      subtenant_id: Keyword.get(opts, :subtenant_id),
      dedup_key: Keyword.get_lazy(opts, :dedup_key, fn -> "dedup-" <> random() end),
      message_class: Keyword.get(opts, :message_class, :transactional),
      sender_type: :system,
      is_test: false,
      deliveries: Keyword.get_lazy(opts, :deliveries, fn -> [delivery()] end)
    }
  end

  @doc "Delivery attributes for the accept path."
  @spec delivery(keyword()) :: map()
  def delivery(opts \\ []) do
    decision = Keyword.get(opts, :decision, :send)

    %{
      id: Relay.Id.generate(),
      channel: Keyword.get(opts, :channel, :email),
      target_kind: Keyword.get(opts, :target_kind, :address),
      target_key: Keyword.get_lazy(opts, :target_key, fn -> :crypto.strong_rand_bytes(32) end),
      decision: decision,
      decision_reason: if(decision == :send, do: nil, else: "test"),
      decision_rule_id: if(decision == :send, do: nil, else: "TEST-1"),
      deferred_until: Keyword.get(opts, :deferred_until),
      fallback_of: Keyword.get(opts, :fallback_of)
    }
  end

  @doc "An accept request with a fresh idempotency key."
  @spec accept_request([map()], keyword()) :: map()
  def accept_request(notifications, opts \\ []) do
    body = Keyword.get_lazy(opts, :body, &random/0)

    %{
      endpoint: Keyword.get(opts, :endpoint, "POST /v1/events"),
      idempotency_key: Keyword.get_lazy(opts, :key, fn -> "key-" <> random() end),
      fingerprint: :crypto.hash(:sha256, body),
      notifications: notifications,
      outbox: Keyword.get(opts, :outbox, []),
      worker: RelayTest.TenantFixture.SendWorker,
      respond: fn accepted -> {202, %{}, Jason.encode!(%{count: length(accepted)})} end,
      seal: fn body -> {:ok, {"sealed:" <> body, Keyword.fetch!(opts, :data_key)}} end
    }
  end

  @doc "A random lowercase hex string."
  @spec random() :: String.t()
  def random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp wrapped, do: <<1>> <> :crypto.strong_rand_bytes(12 + 32 + 16)
end

defmodule RelayTest.TenantFixture.SendWorker do
  @moduledoc "Queue worker standing in for the delivery sender in data layer tests."

  use Oban.Worker, queue: :deliveries

  @impl Oban.Worker
  def perform(_job), do: :ok
end
