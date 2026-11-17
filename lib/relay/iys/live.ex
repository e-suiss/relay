defmodule Relay.Iys.Live do
  @moduledoc """
  İYS on a running node.

  It is the runtime of `Relay.Iys` (`config :relay, Relay.Iys, runtime: Relay.Iys.Live`): an address waiting for its upload is sealed under the tenant's `data` key for the column that stores it, in the commercial consent class, so destroying the tenant's data key shreds it (TN-27); its blind index is the one subscriber addresses and suppressions use (OP-20); the password is resolved from its secret reference of kind `iys_credential` for one call (TN-26); the upload job enters the `l1` lane with its upload row; İYS's request limits are installation-wide rate limits, because İYS counts by the calling address (PC-34); and the business calendar is the active `business_calendar` version (PC-60).

  For the read path (PC-32) a rejection that came from İYS is applied through `Relay.Compliance.refuse/2` with source `iys`, which is never handed back to the refusal sink, and the address of a recipient is opened for the one request that verifies it.

  It is also the refusal sink of `Relay.Compliance` (`config :relay, Relay.Compliance, sink: Relay.Iys.Live`, PC-38): every refusal notice applied in Relay, from the unsubscribe page, an SMS keyword or a complaint, joins the write path as a rejection on its İYS channel.

  It is also the consent sink of the consent copy (`config :relay, Relay.Preferences, consent_sink: Relay.Iys.Live`, E-21): a consent of an İYS channel belongs in the registry when the tenant entered an İYS configuration or the tenant's region is Turkey (PC-27; a region that cannot be read counts as Turkey, the closed side), and a recorded consent goes to the write path with the subscriber's address of the channel. A consent whose subscriber has no such address cannot be written and is announced as `iys.upload_failed`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Access,
      Relay.Compliance,
      Relay.Datasets,
      Relay.Iys,
      Relay.Platform,
      Relay.Preferences,
      Relay.Secrets,
      Relay.Subscribers,
      Relay.Tenancy
    ],
    exports: []

  @behaviour Relay.Iys

  alias Relay.Compliance.RefusalSink
  alias Relay.Iys.Calendar
  alias Relay.Iys.Consent
  alias Relay.Preferences.ConsentSink
  alias Relay.Scope

  @behaviour ConsentSink
  @behaviour RefusalSink

  @table "iys_uploads"
  @column "address_ct"
  @hour_ms 3_600_000

  # TN-27
  @impl Relay.Iys
  def seal(%Scope{} = scope, address) when is_binary(address) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field(scope, key_id), address) do
      {:ok, %{ct: ct, key_id: key_id}}
    end
  end

  # TN-27
  @impl Relay.Iys
  def open(%Scope{} = scope, <<_::128>> = key_id, ct) when is_binary(ct),
    do: Relay.Tenancy.decrypt_field(field(scope, key_id), ct)

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :commercial_consent,
      table: @table,
      column: @column,
      key_id: key_id
    }
  end

  # OP-20
  @impl Relay.Iys
  def digests(%Scope{} = scope, channel, address),
    do: Relay.Subscribers.address_digests(scope, channel, address)

  # TN-26
  @impl Relay.Iys
  def credential(%Scope{} = scope, ref_id) do
    case Relay.Secrets.get(scope, ref_id) do
      {:ok, %{kind: :iys_credential, state: :active}} -> fetched(scope, ref_id)
      {:ok, _other_kind_or_retired} -> :none
      {:error, _error} -> :unavailable
    end
  end

  defp fetched(scope, ref_id) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      {:error, %Relay.Error{code: :secret_retired}} -> :none
      {:error, _error} -> :unavailable
    end
  end

  # T-15
  # PC-30
  @impl Relay.Iys
  def enqueue(%Scope{} = scope, upload_id, priority) do
    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: Relay.Iys.UploadWorker,
      args: Map.put(Scope.to_job_args(scope), "upload_id", Relay.Id.to_string(upload_id)),
      ref_kind: "iys_upload",
      ref_id: upload_id,
      priority: priority
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # E-109
  @impl Relay.Iys
  def report(%Scope{} = scope, upload_id),
    do: Relay.Access.queue_iys_report(scope, %{"upload_id" => Relay.Id.to_string(upload_id)})

  # PC-34
  # T-19
  @impl Relay.Iys
  def rate(kind) do
    enabled? = :relay |> Application.get_env(Relay.Iys, []) |> Keyword.get(:rate_limits, true)
    if enabled?, do: limited(kind), else: :allow
  end

  defp limited(kind) do
    {limit, period_ms} = budget(kind)

    attrs = %{
      id: "iys." <> Atom.to_string(kind),
      algorithm: :gcra,
      unit: :message,
      limit: limit,
      period_ms: period_ms,
      burst: limit
    }

    scope = Relay.Datasets.installation_scope()

    case Relay.Platform.rate_limit(attrs) do
      {:ok, limit} -> checked(Relay.Platform.rate_limit_check(scope, limit, ["iys"], 1, :l2))
      {:error, _invalid} -> :allow
    end
  end

  defp checked({:deny, wait_ms, _rule}), do: {:deny, wait_ms}
  defp checked(_allowed), do: :allow

  defp budget(:token), do: {Relay.Iys.limit("token_requests_per_hour"), @hour_ms}
  defp budget(:status), do: {Relay.Iys.limit("consent_status_requests_per_hour"), @hour_ms}
  defp budget(_api), do: {Relay.Iys.limit("requests_per_second"), 1000}

  # PC-60
  @impl Relay.Iys
  def calendar do
    scope = Relay.Datasets.installation_scope()

    case Relay.Datasets.decide(scope, "business_calendar", & &1) do
      {:ok, {content, _ref}} -> Calendar.parse(content, "TR")
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-32
  # PC-38
  @impl Relay.Iys
  def refuse(%Scope{} = scope, %{} = attrs) do
    case Relay.Compliance.refuse(scope, attrs) do
      {:ok, _applied} -> :ok
      {:error, %Relay.Error{code: :not_found}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # PC-32
  @impl Relay.Iys
  def recipient_address(%Scope{} = scope, <<_::128>> = recipient_id, channel) do
    case address(scope, recipient_id, channel) do
      {:ok, address} when is_binary(address) -> {:ok, address}
      {:ok, _missing} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-27
  @impl ConsentSink
  def registry?(%Scope{} = scope, channel) do
    case Consent.type(channel) do
      {:ok, _type} -> Relay.Iys.configured?(scope) or turkey?(scope)
      :out_of_scope -> false
    end
  end

  defp turkey?(scope) do
    case Relay.Tenancy.tenant(scope) do
      {:ok, %{"region" => region}} -> to_string(region) == "tr"
      _unknown -> true
    end
  end

  # E-21
  # PC-28
  # PC-30
  @impl ConsentSink
  def recorded(%Scope{} = scope, %{recipient_id: recipient_id, channel: channel} = consent) do
    status = if consent.status == "revoked", do: :rejection, else: :approval

    movement = %{
      channel: channel,
      status: status,
      source: consent.source,
      occurred_at: consent.occurred_at,
      origin: :access,
      recipient_type: consent.recipient_type,
      recipient_id: recipient_id,
      consent_id: consent.consent_id,
      brand_subtenant_id: consent.brand_subtenant_id
    }

    case address(scope, recipient_id, channel) do
      {:ok, address} when is_binary(address) ->
        written(scope, Map.put(movement, :address, address))

      {:ok, _missing} ->
        Relay.Iys.unwritable(scope, movement, "address_missing")

      {:error, reason} ->
        {:error, reason}
    end
  end

  # PC-28
  # PC-38
  @impl RefusalSink
  def refused(%Scope{} = scope, %{channel: _channel, address: _address} = notice) do
    case Relay.Iys.write_refusal(scope, notice) do
      {:ok, _written} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp written(scope, movement) do
    case Relay.Iys.write(scope, movement) do
      {:ok, _written} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp address(scope, recipient_id, channel) do
    field = if channel == "email", do: "email", else: "phone"
    read = fn _status -> Relay.Subscribers.personal_record(recipient_id) end

    with {:ok, record} <- Relay.Tenancy.within(scope, read) do
      {:ok, Relay.Subscribers.open_personal(scope, record, [field])[field]}
    end
  end
end
