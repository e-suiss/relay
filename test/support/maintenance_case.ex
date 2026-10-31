defmodule Relay.MaintenanceCase do
  @moduledoc """
  Case template for maintenance tests against the real PostgreSQL database. Maintenance works on committed data (the audit watermark, concurrent detach, cross-tenant discovery), so these tests run outside the SQL sandbox on unboxed connections of `Relay.Repo` and `Relay.Platform.MaintRepo`, and every fixture uses fresh identifiers. The fixture helpers call the stage 1 SQL functions directly.
  """

  use ExUnit.CaseTemplate
  use Boundary, top_level?: true, check: [out: false]

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.MaintRepo
  alias Relay.Repo

  using do
    quote do
      @moduletag :integration
      import Relay.MaintenanceCase
    end
  end

  setup do
    start_supervised!(MaintRepo)
    :ok
  end

  @doc "Runs `fun` with committed, unsandboxed connections of both repositories."
  @spec committed((-> result)) :: result when result: term()
  def committed(fun), do: Sandbox.unboxed_run(Repo, fn -> Sandbox.unboxed_run(MaintRepo, fun) end)

  @doc "A random 32-byte digest."
  @spec digest() :: binary()
  def digest, do: :crypto.strong_rand_bytes(32)

  @doc "System actor parameters of the SQL functions."
  @spec actor() :: [String.t() | nil]
  def actor, do: ["system", "relay:test", "relay", nil]

  @doc "Runs one query on `Relay.Repo` and returns its rows."
  @spec rows!(String.t(), list()) :: [list()] | nil
  def rows!(sql, params \\ []), do: Repo.query!(sql, params).rows

  @doc "Runs one query on `Relay.Platform.MaintRepo` and returns its rows."
  @spec maint_rows!(String.t(), list()) :: [list()] | nil
  def maint_rows!(sql, params \\ []), do: MaintRepo.query!(sql, params).rows

  @doc "Runs `fun` in a transaction scoped to a tenant environment."
  @spec scoped(Relay.Id.t(), String.t() | Relay.Environment.t(), (-> result)) :: result
        when result: term()
  def scoped(tenant_id, environment, fun) do
    environment =
      if is_atom(environment), do: Relay.Environment.dump(environment), else: environment

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT relay_fn.ctx_set($1, $2)", [tenant_id, environment])
        fun.()
      end)

    result
  end

  @doc "Creates a tenant with data, wrapping and blind index keys in both environments."
  @spec tenant!() :: %{
          id: Relay.Id.t(),
          keys: %{String.t() => %{wrap: Relay.Id.t(), data: Relay.Id.t(), bidx: Relay.Id.t()}}
        }
  def tenant! do
    id = Relay.Id.generate()
    [[region]] = rows!("SELECT region FROM relay.installation")
    access = "acc-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    [["created", ^id]] =
      rows!(
        "SELECT result, tenant_id FROM relay_ops.tenant_create($1, $2, $3, $4, $5, $6, NULL, NULL, $7, $8, $9, $10, $11)",
        [id, access, region, "general", "Europe/Istanbul", "tr", digest() | actor()]
      )

    keys =
      Map.new(["live", "test"], fn env ->
        scoped(id, env, fn ->
          {env,
           %{
             wrap: tenant_key!("dek_wrap", nil),
             data: tenant_key!("data", nil),
             bidx: blind_index_key!()
           }}
        end)
      end)

    %{id: id, keys: keys}
  end

  @doc "Registers a tenant key in the current scope."
  @spec tenant_key!(String.t(), Date.t() | nil) :: Relay.Id.t()
  def tenant_key!(purpose, valid_day) do
    id = Relay.Id.generate()

    [["created"]] =
      rows!(
        "SELECT relay_fn.tenant_key_register($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        [
          id,
          purpose,
          valid_day,
          "pkcs11:object=kek;v=1",
          :crypto.strong_rand_bytes(61),
          digest() | actor()
        ]
      )

    id
  end

  @doc "Registers a blind index key in the current scope."
  @spec blind_index_key!() :: Relay.Id.t()
  def blind_index_key! do
    id = Relay.Id.generate()

    [["created"]] =
      rows!(
        "SELECT relay_fn.blind_index_key_register($1, $2, $3, $4, $5, $6, $7)",
        [id, "pkcs11:object=bidx", digest() | actor()]
      )

    id
  end

  @doc "Creates a recipient in the current scope; `dek` is its profile data key in the clear."
  @spec recipient!(%{wrap: Relay.Id.t(), bidx: Relay.Id.t()}, binary()) ::
          {Relay.Id.t(), Relay.Id.t()}
  def recipient!(keys, dek \\ :crypto.strong_rand_bytes(32)) do
    id = Relay.Id.generate()
    dek_id = Relay.Id.generate()

    [["created", ^id]] =
      rows!(
        "SELECT result, recipient_id FROM relay_fn.recipient_create($1, $2, $3, $4, $5, $6, $7, $8)",
        [
          id,
          "subscriber",
          :crypto.strong_rand_bytes(32),
          keys.bidx,
          :crypto.strong_rand_bytes(48),
          dek_id,
          dek,
          keys.wrap
        ]
      )

    {id, dek_id}
  end

  @doc "Creates a subject data key of `class` for a recipient in the current scope."
  @spec subject_key!(Relay.Id.t(), String.t(), Relay.Id.t()) :: Relay.Id.t()
  def subject_key!(recipient_id, class, wrap_id) do
    id = Relay.Id.generate()

    [["created", ^id]] =
      rows!(
        "SELECT result, subject_key_id FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)",
        [id, recipient_id, class, :crypto.strong_rand_bytes(32), wrap_id]
      )

    id
  end

  @doc "Accepts a notification and opens one sendable email delivery for it in the current scope."
  @spec pending_delivery!(Relay.Id.t()) :: {Relay.Id.t(), Relay.Id.t()}
  def pending_delivery!(recipient_id) do
    notification = Relay.Id.generate()
    delivery = Relay.Id.generate()

    [["created", ^notification]] =
      rows!(
        "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [
          notification,
          recipient_id,
          nil,
          "dedup-" <> Base.encode16(:crypto.strong_rand_bytes(6)),
          "transactional",
          nil,
          "system",
          nil,
          nil,
          nil,
          false,
          nil
        ]
      )

    [["opened", ^delivery]] =
      rows!(
        "SELECT result, delivery_id FROM relay_fn.delivery_open($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)",
        [
          delivery,
          notification,
          "email",
          "address",
          nil,
          :crypto.strong_rand_bytes(32),
          nil,
          nil,
          nil,
          "send",
          nil,
          nil,
          nil,
          nil
        ]
      )

    {notification, delivery}
  end

  @doc "Appends an audit record in the current scope and returns its id."
  @spec audit!(String.t()) :: Relay.Id.t()
  def audit!(action \\ "test.recorded") do
    id = Relay.Id.generate()

    [["appended"]] =
      rows!(
        "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [id, action | actor()] ++ [nil, nil, nil, nil, nil, digest()]
      )

    id
  end
end
