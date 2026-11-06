defmodule Relay.Api.ChannelManagement do
  @moduledoc """
  Channel management on the server API (C-25, C-26, C-45): provider accounts, sender identities and channel identities are listed and read; the fields of a provider account that hold no secret, the sub-tenant and country of a sender identity and the application reference of a channel identity change with a JSON Merge Patch under `If-Match`; a sender identity is created and archived and a channel identity retired, and nothing is deleted (OP-73). Adding a provider account or a channel identity, rotating a credential or a key, and reviewing or suspending a sender identity are operator actions (`Relay.Api.ChannelOperations`). A secret is shown only by its fingerprint, version and state (INV-51). The writes run inside the request's transaction.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views
  alias Relay.Channels
  alias Relay.Channels.Live

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type kind :: Channels.managed()

  @prefixes %{account: "pva", sender: "snd", channel_identity: "chi"}
  @paths %{
    account: "/v1/provider_accounts/",
    sender: "/v1/sender_identities/",
    channel_identity: "/v1/channel_identities/"
  }

  @doc "The external identifier prefix of a managed resource."
  @spec prefix(kind()) :: String.t()
  def prefix(kind), do: Map.fetch!(@prefixes, kind)

  # C-45
  # CH-6
  # INV-51
  @doc "The API view of a managed resource row, with the stored secret references by identifier."
  @spec view(kind(), map(), %{Relay.Id.t() => Relay.Secrets.Ref.t()}) :: map()
  def view(:account, a, secrets) do
    %{
      "object" => "provider_account",
      "id" => Views.id("pva", a["id"]),
      "channel" => a["channel"],
      "provider" => a["provider"],
      "ownership" => a["ownership"],
      "role" => a["role"],
      "priority" => a["priority"],
      "weight" => a["weight"],
      "state" => a["state"],
      "traffic" => a["traffic"],
      "verification_state" => a["verification_state"],
      "verified_at" => a["verified_at"],
      "verification_rule_id" => a["verification_rule_id"],
      "health" => a["health"],
      "health_checked_at" => a["health_checked_at"],
      "in_installation" => a["in_installation"],
      "processing_countries" => a["processing_countries"],
      "transfer_basis" => a["transfer_basis"],
      "scc_notified_on" => a["scc_notified_on"],
      "settings" => a["settings"],
      "credential" => secret_view(secrets, a["credential_ref_id"]),
      "version" => a["version"],
      "created_at" => a["created_at"],
      "updated_at" => a["updated_at"]
    }
  end

  # C-25
  # TN-10
  def view(:sender, s, _secrets) do
    %{
      "object" => "sender_identity",
      "id" => Views.id("snd", s["id"]),
      "provider_account_id" => Views.id("pva", s["provider_account_id"]),
      "subtenant_id" => Views.id("stn", s["subtenant_id"]),
      "channel" => s["channel"],
      "kind" => s["kind"],
      "value" => s["value"],
      "country" => s["country"],
      "approval_state" => s["approval_state"],
      "suspended_at" => s["suspended_at"],
      "suspension_rule_id" => s["suspension_rule_id"],
      "sms_type" => s["sms_type"],
      "state" => if(s["archived_at"], do: "archived", else: "active"),
      "archived_at" => s["archived_at"],
      "version" => s["version"],
      "created_at" => s["created_at"],
      "updated_at" => s["updated_at"]
    }
  end

  # C-26
  def view(:channel_identity, c, secrets) do
    %{
      "object" => "channel_identity",
      "id" => Views.id("chi", c["id"]),
      "channel" => c["channel"],
      "kind" => c["kind"],
      "app_ref" => c["app_ref"],
      "secret" => secret_view(secrets, c["secret_ref_id"]),
      "state" => c["state"],
      "version" => c["version"],
      "created_at" => c["created_at"],
      "updated_at" => c["updated_at"]
    }
  end

  defp secret_view(_secrets, nil), do: nil

  defp secret_view(secrets, id) do
    case Map.fetch(secrets, id) do
      {:ok, ref} ->
        %{
          "fingerprint" => Relay.Secrets.Ref.fingerprint_hex(ref),
          "version" => ref.ref_version,
          "state" => Atom.to_string(ref.state)
        }

      :error ->
        nil
    end
  end

  @doc "The identifiers of the secret references a row names."
  @spec secret_ids(kind(), [map()]) :: [Relay.Id.t()]
  def secret_ids(:account, rows),
    do: for(%{"credential_ref_id" => <<_::128>> = id} <- rows, do: id)

  def secret_ids(:channel_identity, rows),
    do: for(%{"secret_ref_id" => <<_::128>> = id} <- rows, do: id)

  def secret_ids(:sender, _rows), do: []

  @doc "The ETag header of a version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # API-56
  @doc "Lists managed resources newest first, in pages."
  @spec list(Relay.Scope.t(), kind(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, kind, page, endpoint) do
    position = &{&1["created_at"], &1["id"]}

    with {:ok, rows} <- read(Channels.list_managed(scope, kind, page.cursor, page.limit)),
         {:ok, secrets} <- read(Relay.Secrets.describe(scope, secret_ids(kind, rows))),
         render = &view(kind, &1, secrets),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, render, position) do
      {:ok, {200, [], body}}
    end
  end

  @doc "Reads a managed resource in its own scoped transactions."
  @spec get(Relay.Scope.t(), kind(), Relay.Id.t()) :: answer()
  def get(scope, kind, id) do
    with {:ok, row} <- read(Channels.get_managed(scope, kind, id)),
         {:ok, row} <- found(kind, row),
         {:ok, secrets} <- read(Relay.Secrets.describe(scope, secret_ids(kind, [row]))) do
      {:ok, {200, [etag(row["version"])], view(kind, row, secrets)}}
    end
  end

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, _reason}), do: {:error, unavailable()}

  @doc "Answers a managed resource as it stands inside the caller's scoped transaction."
  @spec answer(kind(), Relay.Id.t(), 200 | 201 | 202) :: answer()
  def answer(kind, id, status) do
    row = Channels.managed(kind, id)
    secrets = Relay.Secrets.describe(secret_ids(kind, [row]))

    location =
      if status == 201, do: [{"location", Map.fetch!(@paths, kind) <> ext(kind, id)}], else: []

    {:ok, {status, [etag(row["version"]) | location], view(kind, row, secrets)}}
  end

  defp ext(kind, id), do: Relay.ExternalId.encode(prefix(kind), id)

  # C-45
  # CH-6
  # CH-14
  # T-59 (7)
  @doc "Applies a JSON Merge Patch to the fields of a provider account that hold no secret, under its version, inside the request's transaction; a change of settings resets its verification."
  @spec update_account(Relay.Scope.t(), Relay.Id.t(), map(), pos_integer(), Relay.Actor.t()) ::
          answer()
  def update_account(scope, id, body, expected, actor) do
    with {:ok, row} <- current(:account, id, expected),
         {:ok, attrs} <- account_attrs(row, body) do
      case Channels.write_account(attrs, digest(scope, "provider_account.changed", id), actor) do
        {result, _version} when result in [:updated, :unchanged] -> answer(:account, id, 200)
        {:tenant_inactive, _version} -> {:error, tenant_inactive()}
        {_refused, _version} -> {:error, unavailable()}
      end
    end
  end

  defp account_attrs(row, body) do
    with {:ok, scc} <- scc(body, row["scc_notified_on"]) do
      attrs = %{
        id: row["id"],
        channel: row["channel"],
        provider: row["provider"],
        ownership: row["ownership"],
        credential_ref_id: row["credential_ref_id"],
        role: Map.get(body, "role", row["role"]),
        priority: Map.get(body, "priority", row["priority"]),
        weight: Map.get(body, "weight", row["weight"]),
        in_installation: Map.get(body, "in_installation", row["in_installation"]),
        processing_countries: Map.get(body, "processing_countries", row["processing_countries"]),
        transfer_basis: Map.get(body, "transfer_basis", row["transfer_basis"]),
        scc_notified_on: scc,
        settings: Map.get(body, "settings", row["settings"]),
        expected_version: row["version"]
      }

      residency(attrs)
    end
  end

  @doc "Reads the `scc_notified_on` date of a body, or keeps `current` when the body has none."
  @spec scc(map(), Date.t() | nil) :: {:ok, Date.t() | nil} | {:error, Relay.Error.t()}
  def scc(%{"scc_notified_on" => nil}, _current), do: {:ok, nil}

  def scc(%{"scc_notified_on" => text}, _current) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> field("/scc_notified_on", "invalid_format", "not a date")
    end
  end

  def scc(_body, current), do: {:ok, current}

  # CH-6
  @doc "Checks the data residency of provider account attributes: a provider outside the installation names its processing countries, and the scc basis its notification date."
  @spec residency(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def residency(%{in_installation: false, processing_countries: []}),
    do: field("/processing_countries", "required", "a provider outside names its countries")

  def residency(%{transfer_basis: "scc", scc_notified_on: nil}),
    do: field("/scc_notified_on", "required", "the scc basis needs its notification date")

  def residency(attrs), do: {:ok, attrs}

  # C-25
  @doc "Creates a pending sender identity on a provider account inside the request's transaction; `201` with its view."
  @spec create_sender(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create_sender(scope, body, actor) do
    with {:ok, account_id} <- body_id(body["provider_account_id"], "pva", "/provider_account_id"),
         {:ok, subtenant_id} <- optional_id(body["subtenant_id"], "stn", "/subtenant_id"),
         {:ok, account} <- usable_account(account_id),
         :ok <- free_sender(account_id, body["kind"], body["value"]) do
      id = Relay.Id.generate()

      attrs = %{
        id: id,
        provider_account_id: account_id,
        subtenant_id: subtenant_id,
        channel: account["channel"],
        kind: body["kind"],
        value: body["value"],
        country: body["country"],
        approval_state: "pending"
      }

      digest = digest(scope, "sender_identity.changed", id)
      sender_written(Channels.write_sender_identity(attrs, digest, actor), id, 201)
    end
  end

  defp usable_account(id) do
    case Channels.managed(:account, id) do
      nil -> {:error, not_found(:account)}
      %{"state" => "archived"} -> {:error, archived(:account)}
      account -> {:ok, account}
    end
  end

  defp free_sender(account_id, kind, value) do
    if Channels.sender_taken?(account_id, kind, value),
      do: {:error, conflict("a sender identity with this kind and value exists")},
      else: :ok
  end

  defp sender_written({result, _version}, id, status)
       when result in [:created, :updated, :unchanged],
       do: answer(:sender, id, status)

  defp sender_written({:subtenant_not_found, _version}, _id, _status),
    do: {:error, Relay.Error.new(:subtenant_not_found, "no subtenant has this id")}

  defp sender_written({:account_not_found, _version}, _id, _status),
    do: {:error, not_found(:account)}

  # C-25
  # T-59 (7)
  @doc "Applies a JSON Merge Patch to the sub-tenant and country of a sender identity under its version inside the request's transaction."
  @spec update_sender(Relay.Scope.t(), Relay.Id.t(), map(), pos_integer(), Relay.Actor.t()) ::
          answer()
  def update_sender(scope, id, body, expected, actor) do
    with {:ok, row} <- current(:sender, id, expected),
         {:ok, subtenant_id} <- patched_subtenant(body, row["subtenant_id"]) do
      attrs = %{
        id: id,
        provider_account_id: row["provider_account_id"],
        subtenant_id: subtenant_id,
        channel: row["channel"],
        kind: row["kind"],
        value: row["value"],
        country: Map.get(body, "country", row["country"]),
        approval_state: row["approval_state"]
      }

      digest = digest(scope, "sender_identity.changed", id)
      sender_written(Channels.write_sender_identity(attrs, digest, actor), id, 200)
    end
  end

  defp patched_subtenant(%{"subtenant_id" => text}, _current),
    do: optional_id(text, "stn", "/subtenant_id")

  defp patched_subtenant(_body, current), do: {:ok, current}

  # C-26
  # T-59 (7)
  @doc "Applies a JSON Merge Patch to the application reference of a channel identity under its version inside the request's transaction."
  @spec update_channel_identity(
          Relay.Scope.t(),
          Relay.Id.t(),
          map(),
          pos_integer(),
          Relay.Actor.t()
        ) :: answer()
  def update_channel_identity(scope, id, body, expected, actor) do
    with {:ok, row} <- current(:channel_identity, id, expected),
         app_ref = Map.get(body, "app_ref", row["app_ref"]),
         :ok <- free_app_ref(row, app_ref) do
      attrs = %{
        id: id,
        channel: row["channel"],
        kind: row["kind"],
        app_ref: app_ref,
        secret_ref_id: row["secret_ref_id"]
      }

      digest = digest(scope, "channel_identity.changed", id)

      case Channels.write_channel_identity(attrs, digest, actor) do
        {result, _version} when result in [:updated, :unchanged] ->
          answer(:channel_identity, id, 200)

        {:secret_not_found, _version} ->
          {:error, unavailable()}
      end
    end
  end

  defp free_app_ref(%{"app_ref" => app_ref}, app_ref), do: :ok

  defp free_app_ref(row, app_ref) do
    if Channels.app_ref_taken?(row["kind"], app_ref),
      do: {:error, conflict("a channel identity with this kind and app_ref exists")},
      else: :ok
  end

  # C-25
  # C-26
  # OP-73
  # TN-26 (5)
  @doc "Archives a sender identity or retires a channel identity inside the request's transaction; a retired channel identity's secret reference is retired once nothing else names it. Archiving again returns it unchanged."
  @spec archive(Relay.Scope.t(), :sender | :channel_identity, Relay.Id.t(), Relay.Actor.t()) ::
          answer()
  def archive(scope, kind, id, actor) do
    action = if kind == :sender, do: "sender_identity.archived", else: "channel_identity.retired"

    case Channels.archive_managed(kind, id, digest(scope, action, id), actor) do
      {:not_found, _version} ->
        {:error, not_found(kind)}

      {result, _version} ->
        if result == :retired, do: retire_unused(scope, Channels.managed(kind, id), actor)
        answer(kind, id, 200)
    end
  end

  # CH-14
  # CH-52
  @doc "Asks for the verification of a provider account inside the request's transaction (`Relay.Channels.Live.request_settings_check/3`): an account that is not verified becomes pending and its settings check is queued; answers 202 with the account. An archived account is refused."
  @spec verify_account(Relay.Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def verify_account(scope, id, actor) do
    row = Channels.managed(:account, id)

    cond do
      is_nil(row) -> {:error, not_found(:account)}
      archived?(:account, row) -> {:error, archived(:account)}
      true -> verification(Live.request_settings_check(scope, id, actor), id)
    end
  end

  defp verification(:not_found, _id), do: {:error, not_found(:account)}
  defp verification(_state, id), do: answer(:account, id, 202)

  defp retire_unused(scope, %{"secret_ref_id" => secret_id}, actor) do
    unless Channels.secret_in_use?(secret_id) do
      digest = digest(scope, "secret_ref.retired", Relay.Id.to_string(secret_id))
      Relay.Secrets.retire(secret_id, digest, actor)
    end
  end

  defp current(kind, id, expected) do
    row = Channels.managed(kind, id, lock: true)

    cond do
      is_nil(row) -> {:error, not_found(kind)}
      archived?(kind, row) -> {:error, archived(kind)}
      expected != row["version"] -> {:error, stale()}
      true -> {:ok, row}
    end
  end

  @doc "Whether a managed row is archived or retired."
  @spec archived?(kind(), map()) :: boolean()
  def archived?(:account, row), do: row["state"] == "archived"
  def archived?(:sender, row), do: row["archived_at"] != nil
  def archived?(:channel_identity, row), do: row["state"] == "retired"

  defp found(kind, nil), do: {:error, not_found(kind)}
  defp found(_kind, row), do: {:ok, row}

  defp body_id(text, prefix, pointer) do
    case Relay.ExternalId.decode(text || "", [prefix]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> field(pointer, "invalid_format", "not a #{prefix}_ identifier")
    end
  end

  defp optional_id(nil, _prefix, _pointer), do: {:ok, nil}
  defp optional_id(text, prefix, pointer), do: body_id(text, prefix, pointer)

  @doc "A record digest over an action, the scope and a reference."
  @spec digest(Relay.Scope.t(), String.t(), Relay.Id.t() | String.t()) :: <<_::256>>
  def digest(scope, action, ref) do
    ref = if Relay.Id.valid?(ref), do: Relay.Id.to_string(ref), else: ref
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end

  @doc "The error of an unknown managed resource."
  @spec not_found(kind()) :: Relay.Error.t()
  def not_found(:account),
    do: Relay.Error.new(:provider_account_not_found, "no provider account has this id")

  def not_found(:sender),
    do: Relay.Error.new(:sender_identity_not_found, "no sender identity has this id")

  def not_found(:channel_identity),
    do: Relay.Error.new(:channel_identity_not_found, "no channel identity has this id")

  @doc "The error of a change to an archived or retired managed resource."
  @spec archived(kind()) :: Relay.Error.t()
  def archived(:account),
    do: Relay.Error.new(:provider_account_archived, "the provider account is archived")

  def archived(:sender),
    do: Relay.Error.new(:sender_identity_archived, "the sender identity is archived")

  def archived(:channel_identity),
    do: Relay.Error.new(:channel_identity_retired, "the channel identity is retired")

  @doc "The error of a resource that already exists."
  @spec conflict(String.t()) :: Relay.Error.t()
  def conflict(message), do: Relay.Error.new(:resource_conflict, message)

  defp stale, do: Relay.Error.new(:precondition_failed, "the resource changed; read it again")

  defp tenant_inactive, do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")

  @doc "The error of a read or write that could not complete."
  @spec unavailable() :: Relay.Error.t()
  def unavailable,
    do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
