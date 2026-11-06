defmodule Relay.Api.ChannelOperations do
  @moduledoc """
  The channel management actions of the operator surface (TN-21, TN-26): adding and archiving a provider account and rotating its credential, adding a channel identity and rotating its key, reviewing a sender identity, and the installation operator's suspension of a sender identity (TN-10). Each runs in its own scoped transactions after the operator pipeline checked the role and the step-up. A secret is taken only as a reference, `${VAR}` or `pkcs11:object=<label>`, registered once with its fingerprint (`Relay.Secrets.register_ref/6`); a rotated reference is retired once nothing names it and the holders of the secret are signalled. Answers are `{:ok, {status, body}}` or `{:error, error}`.
  """

  alias Relay.Api.ChannelManagement, as: Views
  alias Relay.Channels

  @type answer :: {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()}

  # C-45
  # CH-6
  # CH-14
  # TN-21
  # TN-26 (2)
  @doc "Adds a provider account; a tenant-owned account names its credential by reference, a shared account is added only by the installation operator (`installation?`). It starts unverified."
  @spec create_account(Relay.Scope.t(), map(), Relay.Actor.t(), boolean()) :: answer()
  def create_account(scope, body, actor, installation?) do
    id = Relay.Id.generate()

    with :ok <- ownership(body, installation?),
         {:ok, scc} <- Views.scc(body, nil),
         {:ok, attrs} <- Views.residency(account_attrs(body, id, scc)),
         {:ok, credential_id} <- credential(scope, body, actor) do
      attrs = Map.put(attrs, :credential_ref_id, credential_id)
      digest = Views.digest(scope, "provider_account.changed", id)
      created(Channels.put_account(scope, attrs, digest, actor), scope, id)
    end
  end

  defp account_attrs(body, id, scc) do
    %{
      id: id,
      channel: body["channel"],
      provider: body["provider"],
      ownership: body["ownership"],
      role: body["role"],
      priority: body["priority"],
      weight: Map.get(body, "weight", 0),
      in_installation: Map.get(body, "in_installation", false),
      processing_countries: Map.get(body, "processing_countries", []),
      transfer_basis: body["transfer_basis"],
      scc_notified_on: scc,
      settings: Map.get(body, "settings", %{})
    }
  end

  defp ownership(%{"ownership" => "tenant"} = body, _installation?) do
    if is_binary(body["credential_ref"]),
      do: :ok,
      else: field("/credential_ref", "required", "a tenant-owned account names its credential")
  end

  defp ownership(%{"credential_ref" => _ref}, _installation?),
    do: field("/credential_ref", "not_allowed", "a shared account uses the installation's")

  defp ownership(_body, true), do: :ok

  defp ownership(_body, false) do
    message = "only the installation operator adds a shared account"

    {:error,
     Relay.Error.new(:auth_insufficient_role, message, %{
       required_role: "installation_operator",
       granted_roles: []
     })}
  end

  defp credential(scope, %{"credential_ref" => ref}, actor) do
    with {:ok, registered} <- register(scope, :provider_credential, ref, 1, actor),
         do: {:ok, registered.id}
  end

  defp credential(_scope, _body, _actor), do: {:ok, nil}

  defp created({:ok, {:created, _version}}, scope, id), do: view(scope, :account, id, 201)

  defp created({:ok, {:tenant_inactive, _version}}, _scope, _id),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  defp created(_refused, _scope, _id), do: {:error, Views.unavailable()}

  # C-45
  # TN-21
  # OP-73
  @doc "Archives a provider account: it leaves every route and its row stays; its credential reference is retired once nothing else names it."
  @spec archive_account(Relay.Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive_account(scope, id, actor) do
    with {:ok, row} <- fetch(scope, :account, id) do
      digest = Views.digest(scope, "provider_account.archived", id)

      case Channels.archive_account(scope, id, digest, actor) do
        {:ok, {result, _version}} when result in [:archived, :already_archived] ->
          _ = retire_unused(scope, row["credential_ref_id"], actor)
          view(scope, :account, id, 200)

        _failed ->
          {:error, Views.unavailable()}
      end
    end
  end

  # TN-21
  # TN-26 (5)
  @doc "Points a tenant-owned provider account at a new credential reference with the step-up record of the change, retires the old reference once nothing names it and signals the holders, who fetch the secret again without a restart."
  @spec rotate_credential(
          Relay.Scope.t(),
          Relay.Id.t(),
          map(),
          String.t() | nil,
          Relay.Actor.t()
        ) :: answer()
  def rotate_credential(scope, id, body, step_up_ref, actor) do
    with {:ok, row} <- fetch(scope, :account, id),
         :ok <- rotatable(row),
         old = row["credential_ref_id"],
         text = body["credential_ref"],
         {:ok, ref} <- register(scope, :provider_credential, text, next(scope, old), actor) do
      digest = Views.digest(scope, "provider_account.credential_rotated", id)

      scope
      |> Channels.rotate_credential(id, ref.id, step_up_ref, digest, actor)
      |> rotated(scope, {:account, id}, old, ref, actor)
    end
  end

  defp rotatable(row) do
    cond do
      Views.archived?(:account, row) ->
        {:error, Views.archived(:account)}

      row["ownership"] != "tenant" ->
        {:error, Relay.Error.new(:provider_account_shared, "a shared account has no credential")}

      true ->
        :ok
    end
  end

  defp rotated({:ok, result}, scope, {kind, id}, old, ref, actor)
       when result in [:rotated, :updated, :unchanged] do
    _ = retire_unused(scope, old, actor)
    _ = Relay.Secrets.signal_rotation(scope, ref.ref_version)
    view(scope, kind, id, 200)
  end

  defp rotated({:ok, :step_up_required}, _scope, _target, _old, _ref, _actor),
    do: {:error, Relay.Error.new(:auth_step_up_required, "this change needs a fresh step-up")}

  defp rotated(_failed, _scope, _target, _old, _ref, _actor), do: {:error, Views.unavailable()}

  # C-26
  # TN-21
  # TN-26 (2)
  @doc "Adds a channel identity whose secret is named by reference."
  @spec create_channel_identity(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create_channel_identity(scope, body, actor) do
    id = Relay.Id.generate()

    with :ok <- free_app_ref(scope, body["kind"], body["app_ref"]),
         {:ok, ref} <- register(scope, :channel_identity, body["secret_ref"], 1, actor) do
      attrs = %{
        id: id,
        channel: body["channel"],
        kind: body["kind"],
        app_ref: body["app_ref"],
        secret_ref_id: ref.id
      }

      digest = Views.digest(scope, "channel_identity.changed", id)

      case Channels.put_channel_identity(scope, attrs, digest, actor) do
        {:ok, {:created, _version}} -> view(scope, :channel_identity, id, 201)
        _failed -> {:error, Views.unavailable()}
      end
    end
  end

  defp free_app_ref(scope, kind, app_ref) do
    case Channels.app_ref_taken?(scope, kind, app_ref) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, Views.conflict("a channel identity has this kind and app_ref")}
      {:error, _reason} -> {:error, Views.unavailable()}
    end
  end

  # C-26
  # TN-21
  # TN-26 (5)
  @doc "Points a channel identity at a new secret reference, retires the old reference once nothing names it and signals the holders."
  @spec rotate_channel_identity(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) ::
          answer()
  def rotate_channel_identity(scope, id, body, actor) do
    with {:ok, row} <- fetch(scope, :channel_identity, id),
         :ok <- active(:channel_identity, row),
         old = row["secret_ref_id"],
         text = body["secret_ref"],
         {:ok, ref} <- register(scope, :channel_identity, text, next(scope, old), actor) do
      attrs = %{
        id: id,
        channel: row["channel"],
        kind: row["kind"],
        app_ref: row["app_ref"],
        secret_ref_id: ref.id
      }

      digest = Views.digest(scope, "channel_identity.changed", id)

      scope
      |> Channels.put_channel_identity(attrs, digest, actor)
      |> identity_rotated()
      |> rotated(scope, {:channel_identity, id}, old, ref, actor)
    end
  end

  defp identity_rotated({:ok, {result, _version}}), do: {:ok, result}
  defp identity_rotated(failed), do: failed

  # C-25
  @doc "Records the review of a sender identity: `pending`, `approved` or `rejected`."
  @spec review_sender(Relay.Scope.t(), Relay.Id.t(), String.t(), Relay.Actor.t()) :: answer()
  def review_sender(scope, id, approval_state, actor) do
    digest = Views.digest(scope, "sender_identity.changed", id)

    case Channels.review_sender_identity(scope, id, approval_state, digest, actor) do
      {:ok, {result, _version}} when result in [:updated, :unchanged] ->
        view(scope, :sender, id, 200)

      {:ok, {:archived, _version}} ->
        {:error, Views.archived(:sender)}

      {:ok, {:not_found, _version}} ->
        {:error, Views.not_found(:sender)}

      _failed ->
        {:error, Views.unavailable()}
    end
  end

  # TN-10
  # TN-21
  @doc "Suspends a sender identity apart from its tenant with a rule identifier (`rule_id`), or resumes it (`nil`)."
  @spec suspend_sender(Relay.Scope.t(), Relay.Id.t(), String.t() | nil, Relay.Actor.t()) ::
          answer()
  def suspend_sender(scope, id, rule_id, actor) do
    action = if rule_id, do: "sender_identity.suspended", else: "sender_identity.resumed"
    digest = Views.digest(scope, action, id)

    case Channels.suspend_sender_identity(scope, id, rule_id != nil, rule_id, digest, actor) do
      {:ok, :not_found} -> {:error, Views.not_found(:sender)}
      {:ok, _changed} -> view(scope, :sender, id, 200)
      {:error, _reason} -> {:error, Views.unavailable()}
    end
  end

  defp fetch(scope, kind, id) do
    case Channels.get_managed(scope, kind, id) do
      {:ok, %{} = row} -> {:ok, row}
      {:ok, nil} -> {:error, Views.not_found(kind)}
      {:error, _reason} -> {:error, Views.unavailable()}
    end
  end

  defp active(kind, row) do
    if Views.archived?(kind, row), do: {:error, Views.archived(kind)}, else: :ok
  end

  defp next(_scope, nil), do: 1

  defp next(scope, old) do
    case Relay.Secrets.describe(scope, [old]) do
      {:ok, %{^old => ref}} -> ref.ref_version + 1
      _none -> 1
    end
  end

  defp register(scope, kind, text, version, actor) do
    pointer = if kind == :provider_credential, do: "/credential_ref", else: "/secret_ref"
    digest = Views.digest(scope, "secret_ref.registered", Atom.to_string(kind))

    case Relay.Secrets.register_ref(scope, kind, text, version, digest, actor) do
      {:ok, ref} -> {:ok, ref}
      {:error, %Relay.Error{code: code}} -> secret_error(code, pointer)
    end
  end

  defp secret_error(:invalid_secret_ref, pointer),
    do: field(pointer, "invalid_format", "a secret reference is ${VAR} or pkcs11:object=")

  defp secret_error(:secret_unavailable, pointer),
    do: field(pointer, "not_found", "the secret reference does not resolve")

  defp secret_error(:secret_retired, pointer),
    do: field(pointer, "conflict", "this secret was retired; rotate to a new one")

  defp secret_error(_code, _pointer), do: {:error, Views.unavailable()}

  defp retire_unused(_scope, nil, _actor), do: :ok

  defp retire_unused(scope, secret_id, actor) do
    digest = Views.digest(scope, "secret_ref.retired", secret_id)

    case Channels.secret_in_use?(scope, secret_id) do
      {:ok, false} -> Relay.Secrets.retire(scope, secret_id, digest, actor)
      _kept -> :ok
    end
  end

  defp view(scope, kind, id, status) do
    case Views.get(scope, kind, id) do
      {:ok, {_status, _headers, body}} -> {:ok, {status, body}}
      {:error, error} -> {:error, error}
    end
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
