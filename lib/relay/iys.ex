defmodule Relay.Iys do
  @moduledoc """
  İYS, the national commercial message consent registry of Turkey (§13.6). Relay is the one writer of a brand: consents and refusals are written here and nowhere else (PC-28, E-20, E-21).

  * **Configuration (PC-29, E-22).** A tenant environment connects with its own İYS access (`own`) or through its authorised integrator (`integrator`); both are served alike. The model is `iysCode → (brandCode, type) → consent`: a tenant carries one or more brands, each bound to the tenant, to a sub-tenant or to an SMS sender identity whose registration names the same `brandCode`. The password is only a secret reference of kind `iys_credential`. An integrator's access by type is read from its authorisation list on a schedule and never assumed: until it was read, and when it is older than the published maximum age, nothing is written for the brand.
  * **Write path (PC-30).** A consent movement becomes an upload row with its job in one transaction; the address is sealed under the tenant's data key and cleared when the upload settles. The job sends the movement with the idempotent v2 operation, one at a time for a recipient, brand and type, reads the status back and only then appends `active` (or `revoked`) with the İYS transaction identifier to the consent copy. A refusal takes the same path ahead of the approvals and withdraws an approval of the same recipient that was not sent yet. An approval that İYS did not record within three business days (`Relay.Iys.Calendar`) becomes `expired`; a movement İYS refuses for good stays `failed` for the operator and is announced to the tenant.
  * **Operation (PC-34).** The token is cached for its lifetime, a request İYS would refuse is checked before it is sent (`Relay.Iys.Consent`), İYS's limits are the published limits `iys`, and the consent quota is watched.

  The node reaches the other contexts through its runtime (`config :relay, Relay.Iys, runtime: Module`), `Relay.Iys.Live` on a running node.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay],
    exports: [Calendar, Client, Consent, Sweep, TokenCache, UploadWorker]

  alias Relay.Actor
  alias Relay.Iys.Calendar
  alias Relay.Iys.Client
  alias Relay.Iys.Connection
  alias Relay.Iys.Consent
  alias Relay.Iys.Store
  alias Relay.Iys.Uploads
  alias Relay.Scope

  @type result(value) :: {:ok, value} | {:error, term()}
  @type movement :: %{
          required(:channel) => String.t(),
          required(:status) => :approval | :rejection,
          required(:address) => String.t(),
          required(:source) => String.t() | nil,
          required(:occurred_at) => DateTime.t(),
          required(:origin) => :access | :refusal,
          optional(:recipient_type) => String.t() | nil,
          optional(:recipient_id) => Relay.Id.t() | nil,
          optional(:consent_id) => Relay.Id.t() | nil,
          optional(:brand_subtenant_id) => Relay.Id.t() | nil,
          optional(:brand_code) => pos_integer()
        }
  @type written :: :queued | :duplicate | :not_configured | :out_of_scope | :brand_not_mapped
  @type swept :: %{expired: non_neg_integer(), queued: non_neg_integer()}

  @doc "Seals an address under the scope's active data key for the upload row; runs outside any transaction."
  @callback seal(Scope.t(), String.t()) ::
              {:ok, %{ct: binary(), key_id: Relay.Id.t()}} | {:error, term()}

  @doc "Opens a sealed address; runs outside any transaction."
  @callback open(Scope.t(), Relay.Id.t(), binary()) ::
              {:ok, Relay.Redacted.t()} | {:error, term()}

  @doc "The blind indexes of an address under every readable key, the current key first; runs outside any transaction."
  @callback digests(Scope.t(), String.t(), String.t()) ::
              {:ok, [{Relay.Id.t(), <<_::256>>}, ...]} | {:error, term()}

  @doc "Resolves the password of a configuration from its secret reference for this call only."
  @callback credential(Scope.t(), Relay.Id.t()) ::
              {:ok, Relay.Redacted.t()} | :none | :unavailable

  @doc "Queues the upload job of an upload inside the caller's scoped transaction; `priority` 0 is served first."
  @callback enqueue(Scope.t(), Relay.Id.t(), 0..9) :: :ok | {:error, term()}

  @doc "Asks the installation-wide limiter of İYS requests of `kind` (`:api`, `:status` or `:token`)."
  @callback rate(atom()) :: :allow | {:deny, non_neg_integer()}

  @doc "The business calendar of Turkey from the active `business_calendar` version."
  @callback calendar() :: {:ok, Calendar.t()} | {:error, term()}

  @doc "Supervised children: the token cache."
  @spec children() :: [module()]
  def children, do: [Relay.Iys.TokenCache]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Scope.t(), (atom() -> term())) :: result(term())
  defdelegate in_scope(scope, fun), to: Store

  # PC-29
  @doc "The İYS configuration of the scope and its active brands; `config` is `nil` when the tenant entered none."
  @spec get_config(Scope.t()) :: result(%{config: map() | nil, brands: [map()]})
  def get_config(%Scope{} = scope), do: Store.in_scope(scope, fn _status -> stored_config() end)

  @doc "Reads the configuration and brands inside the caller's scoped transaction."
  @spec stored_config() :: %{config: map() | nil, brands: [map()]}
  def stored_config, do: %{config: Store.config(), brands: Store.brands()}

  # PC-27
  @doc "Whether the scope entered an İYS configuration."
  @spec configured?(Scope.t()) :: boolean()
  def configured?(%Scope{} = scope) do
    case Store.in_scope(scope, fn _status -> Store.config() end) do
      {:ok, %{}} -> true
      _none -> false
    end
  end

  # PC-29
  # E-22
  @doc "Writes the configuration and replaces the brand set inside the caller's scoped transaction. `config` carries `mode`, `api`, `iys_code`, `integrator_code`, `username` and `credential_ref_id`; each brand `brand_code`, `name`, `subtenant_id` and `sender_identity_id`. `expected_version` guards the write when it is given."
  @spec put_config(map(), [map()], pos_integer() | nil, binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def put_config(config, brands, expected_version, digest, %Actor{} = actor) do
    brands = Enum.map(brands, &Map.put(&1, "id", Relay.Id.to_string(Relay.Id.generate())))
    Store.config_put(Relay.Id.generate(), config, brands, expected_version, digest, actor)
  end

  # PC-30
  # API-56
  @doc "A page of uploads, newest first, optionally of one state (`failed` is the operator's queue of permanent failures); at most `limit + 1` rows."
  @spec list_uploads(Scope.t(), String.t() | nil, map() | nil, pos_integer()) :: result([map()])
  def list_uploads(%Scope{} = scope, state, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.uploads(state, cursor, limit) end)

  # PC-29
  # PC-34
  @doc "Tests the connection outside any transaction: gets a token, lists the brands (the authorisations in integrator mode) and reads the subscription. Answers what each step found; nothing is written."
  @spec test_connection(Scope.t()) :: result(map())
  def test_connection(%Scope{} = scope) do
    case get_config(scope) do
      {:ok, %{config: %{} = config, brands: brands}} ->
        {:ok, Connection.test(scope, config, brands)}

      {:ok, %{config: nil}} ->
        {:error, :not_configured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # PC-28
  # PC-30
  # E-21
  @doc """
  Sends a consent movement through the write path: the upload row and its job commit in one transaction and the İYS request follows from the queue. Call it outside any transaction. A channel İYS does not know is `:out_of_scope`, a scope without a configuration `:not_configured`; a movement whose brand is not configured is recorded as failed and announced (`:brand_not_mapped`). The same consent, or a refusal that is already waiting for the same recipient, brand and type, is `:duplicate`.
  """
  @spec write(Scope.t(), movement()) :: result(written())
  def write(%Scope{} = scope, %{} = movement), do: Uploads.write(scope, movement)

  # PC-28
  # PC-30
  # PC-38
  @doc """
  Writes a refusal of a recipient for a brand and channel to İYS (the refusal sink of the unsubscribe page, the SMS keyword and the complaint). The refusal was applied in Relay before this is called; here it only joins the write path, ahead of the approvals. `refusal` carries `:brand` (an İYS brand code, a sub-tenant identifier, or `nil` for the tenant's own brand), `:channel`, `:address` (in clear or redacted), `:recipient_type`, `:source` and `:occurred_at`, and optionally `:recipient_id`.
  """
  @spec write_refusal(Scope.t(), map()) :: result(written())
  def write_refusal(%Scope{} = scope, %{channel: channel, address: address} = refusal)
      when is_binary(channel) do
    movement = %{
      channel: channel,
      status: :rejection,
      address: exposed(address),
      source: Map.get(refusal, :source),
      occurred_at: Map.get(refusal, :occurred_at) || Relay.Clock.utc_now(),
      origin: :refusal,
      recipient_type: Map.get(refusal, :recipient_type),
      recipient_id: Map.get(refusal, :recipient_id)
    }

    Uploads.write(scope, Map.merge(movement, brand(Map.get(refusal, :brand))))
  end

  defp exposed(%Relay.Redacted{} = address), do: Relay.Redacted.expose(address)
  defp exposed(address) when is_binary(address), do: address

  defp brand(code) when is_integer(code), do: %{brand_code: code}
  defp brand(<<_::128>> = subtenant_id), do: %{brand_subtenant_id: subtenant_id}
  defp brand(_tenant), do: %{brand_subtenant_id: nil}

  # PC-30
  # PC-34
  @doc "Announces a movement that cannot enter the write path at all (`iys.upload_failed` with `error_code`), so that it is not lost silently; `movement` carries `:channel`, `:status` and optionally `:recipient_id`."
  @spec unwritable(Scope.t(), map(), String.t()) :: :ok | {:error, term()}
  defdelegate unwritable(scope, movement, error_code), to: Uploads

  # PC-30
  @doc "Runs one attempt of an upload; the job of the write path. Answers `:done`, `{:snooze, seconds}` or `{:error, reason}`."
  @spec run_upload(Scope.t(), Relay.Id.t()) :: :done | {:snooze, pos_integer()} | {:error, term()}
  defdelegate run_upload(scope, upload_id), to: Uploads, as: :run

  # PC-30
  # PC-31
  @doc "Expires the approvals of the scope whose three business days ended at `now` and queues again the open uploads no attempt touched for a while; answers how many it expired and queued."
  @spec sweep(Scope.t(), DateTime.t()) :: result(swept())
  defdelegate sweep(scope, now), to: Uploads

  # PC-29
  # PC-34
  # PC-62
  @doc "Refreshes what İYS says about the connection of the scope: the integrator's authorisations and the consent quota, with the tenant warning when the quota nears its limit or is full."
  @spec refresh(Scope.t(), DateTime.t()) :: result(map())
  defdelegate refresh(scope, now), to: Connection

  # PC-34
  # PC-62
  @doc "A published İYS limit (`x-relay-limits.iys`)."
  @spec limit(String.t()) :: term()
  def limit(name), do: Relay.Limits.fetch!(["iys", name])

  @doc "The API a configuration talks to: its base address."
  @spec base_url(String.t()) :: String.t()
  def base_url(api) do
    defaults = %{
      "production" => "https://api.iys.org.tr",
      "sandbox" => "https://api.sandbox.iys.org.tr"
    }

    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:base_urls, defaults)
    |> Map.fetch!(api)
  end

  @doc "The runtime of the context."
  @spec runtime() :: module()
  def runtime, do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.fetch!(:runtime)

  # PC-34
  @doc "The client connection of a configuration: its codes, its user name and its password resolved for this call."
  @spec connection(Scope.t(), map()) :: {:ok, Client.conn()} | {:error, :credential_unavailable}
  def connection(%Scope{} = scope, %{} = config) do
    runtime = runtime()

    case runtime.credential(scope, config["credential_ref_id"]) do
      {:ok, password} ->
        {:ok,
         %{
           base_url: base_url(config["api"]),
           iys_code: config["iys_code"],
           integrator_code: config["integrator_code"],
           username: config["username"],
           password: password,
           cache_key: {scope.tenant_id, scope.environment, config["id"], config["version"]},
           rate: &runtime.rate/1
         }}

      _missing ->
        {:error, :credential_unavailable}
    end
  end

  @doc "The Relay view of a consent movement's type and status for an event or the API."
  @spec describe(map()) :: %{channel: String.t() | nil, status: String.t()}
  def describe(%{"consent_type" => type, "consent_status" => status}) do
    %{
      channel: Consent.channel(type),
      status: if(status == "ONAY", do: "approval", else: "rejection")
    }
  end
end
