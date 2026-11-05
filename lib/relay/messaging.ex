defmodule Relay.Messaging do
  @moduledoc """
  The messaging channels Slack, Microsoft Teams, Telegram and Discord around their adapters (CH-62): where a recipient is reached, which message of a subject an update edits, the per-workspace installation of a tenant's bot or app, the inbound interactions, and the adapters' version and deprecation warnings. Other contexts use only the functions of this module.

    * A recipient's conversation on a channel (`relay.messaging_targets`) belongs to one installation, a provider account of the channel; its value (a user, chat or channel ID, or a Teams conversation reference) is personal data and is sealed under the recipient's data key (C-22).
    * Collapse (CH-23): the message a delivery posted is kept under its subject key, the digest of `{tenant, subject type, subject ID, message class}`; the next delivery about the same subject in the same conversation edits that message.
    * Installation: one provider account per workspace of a channel identity. Slack and Discord install with OAuth through a sealed `state`; the Slack bot token is stored as a secret data object in the key store and only its reference is kept (TN-26). Telegram registers the bot's webhook. A Teams installation is recorded when the bot's own installation update arrives.
    * Inbound interactions (WH-49): the provider's signature is verified on the raw body, the receipt is committed with its processing job before the provider gets its fast `2xx`, and a repeated provider event is counted, not processed again. An interaction is an event only (`messaging_interaction.received`); a card button or an inline reply is never an approval (CH-62, INV-29).
    * Adapter versions (CH-4): every adapter declares its version and the provider APIs it uses that are deprecated; a tenant that uses such a provider gets the warning in the API and the `channel_adapter.deprecated` event.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Audit,
      Relay.Channels,
      Relay.Datasets,
      Relay.Platform,
      Relay.Secrets,
      Relay.Tenancy,
      Relay.Webhooks
    ],
    exports: []

  alias Relay.ChannelDeclarations
  alias Relay.Messaging.Inbound
  alias Relay.Messaging.Install
  alias Relay.Messaging.Store
  alias Relay.Messaging.TeamsAuth
  alias Relay.Redacted
  alias Relay.Scope

  @channels ~w(slack teams telegram discord)
  @oauth ~w(slack discord)
  @kinds %{
    "slack" => "slack_app",
    "teams" => "teams_bot",
    "telegram" => "telegram_bot",
    "discord" => "discord_bot"
  }
  @domain "relay.collapse.v1"
  @hosts ~r/(\A|\.)(botframework\.com|trafficmanager\.net|botframework\.azure\.us)\z/
  @id ~r/\A(user:)?[A-Za-z0-9_.:@-]{1,128}\z/

  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "The messaging channels."
  @spec channels() :: [String.t(), ...]
  def channels, do: @channels

  # CH-62
  @doc "Returns true when `value` is a valid conversation of the channel: an ID, or for Teams a conversation reference whose service URL is an `https` Bot Framework host."
  @spec valid_target?(String.t(), String.t() | map()) :: boolean()
  def valid_target?("teams", %{"service_url" => url, "conversation_id" => id})
      when is_binary(url) and is_binary(id) and id != "" do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        Regex.match?(@hosts, String.downcase(host)) and byte_size(id) <= 512

      _other ->
        false
    end
  end

  def valid_target?(channel, value) when channel in ["slack", "telegram", "discord"],
    do: is_binary(value) and Regex.match?(@id, value)

  def valid_target?(_channel, _value), do: false

  defp encode_target("teams", %{} = reference) do
    Jason.encode!(Map.take(reference, ["service_url", "conversation_id"]))
  end

  defp encode_target(_channel, value), do: value

  # CH-62
  # C-22
  @doc "Seals a recipient's conversation outside any transaction; the result is written with `put_target/2` inside the caller's scoped transaction."
  @spec prepare_target(Scope.t(), Relay.Id.t(), String.t(), Relay.Id.t(), String.t() | map()) ::
          result(map())
  def prepare_target(%Scope{} = scope, recipient_id, channel, account_id, value) do
    case Relay.Tenancy.encrypt_field(field(scope, recipient_id), encode_target(channel, value)) do
      {:ok, ct} ->
        {:ok,
         %{
           id: Relay.Id.generate(),
           recipient_id: recipient_id,
           channel: channel,
           account_id: account_id,
           target_ct: ct
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # CH-62
  @doc "Writes a prepared conversation inside the caller's scoped transaction; an earlier conversation of the recipient on the channel is replaced. Returns the result and the conversation's identifier."
  @spec put_target(map()) :: {atom(), Relay.Id.t() | nil}
  def put_target(p),
    do: Store.target_put(p.id, p.recipient_id, p.channel, p.account_id, p.target_ct)

  # CH-11
  # CH-62
  @doc "Disables a recipient's conversation on a channel inside the caller's scoped transaction."
  @spec remove_target(Relay.Id.t(), String.t(), String.t()) ::
          {:disabled | :not_found, Relay.Id.t() | nil}
  def remove_target(recipient_id, channel, rule_id),
    do: Store.target_disable(recipient_id, channel, rule_id)

  # CH-62
  @doc "A conversation by identifier inside the caller's scoped transaction, or `nil`; its value is never read."
  @spec get_target(Relay.Id.t()) :: map() | nil
  defdelegate get_target(id), to: Store, as: :target_by_id

  # CH-11
  # INV-14
  @doc "Disables a recipient's conversation after a permanent target failure, in its own transaction, and announces `messaging_target.disabled`."
  @spec disable_target(Scope.t(), Relay.Id.t(), String.t(), String.t()) ::
          result({:disabled | :not_found, Relay.Id.t() | nil})
  def disable_target(%Scope{} = scope, recipient_id, channel, rule_id),
    do: Store.in_scope(scope, fn _status -> remove_target(recipient_id, channel, rule_id) end)

  # CH-62
  @doc "The active conversation of a recipient on a channel, read in its own transaction and decrypted outside it: its identifier, provider account and value, redacted."
  @spec target(Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, %{id: Relay.Id.t(), account_id: Relay.Id.t(), value: Redacted.t()}}
          | :none
          | {:error, term()}
  def target(%Scope{} = scope, recipient_id, channel) do
    case Store.in_scope(scope, fn _status -> Store.target(recipient_id, channel) end) do
      {:ok, %{} = row} ->
        decrypted(scope, recipient_id, row)

      {:ok, nil} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decrypted(scope, recipient_id, row) do
    case Relay.Tenancy.decrypt_field(field(scope, recipient_id), row["target_ct"]) do
      {:ok, value} ->
        {:ok, %{id: row["id"], account_id: row["provider_account_id"], value: value}}

      {:error, _reason} ->
        :none
    end
  end

  defp field(scope, recipient_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "messaging_targets",
      column: "target_ct"
    }
  end

  # CH-23
  @doc "The subject key of a notification: the SHA-256 of `{tenant, subject type, subject ID, message class}`, each length-prefixed under a domain label."
  @spec topic_key(Relay.Id.t(), String.t(), String.t(), String.t()) :: <<_::256>>
  def topic_key(tenant_id, subject_type, subject_id, message_class) do
    fields = [@domain, tenant_id, subject_type, subject_id, message_class]
    :crypto.hash(:sha256, Enum.map(fields, &[<<byte_size(&1)::32>>, &1]))
  end

  # CH-23
  @doc "The earlier message of a delivery's subject in a conversation, in its own transaction: the subject key and the provider message reference to edit, or `nil`s when the delivery has no subject or the subject no message yet."
  @spec update_ref(Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          result({<<_::256>> | nil, String.t() | nil})
  def update_ref(%Scope{} = scope, target_id, delivery_id) do
    Store.in_scope(scope, fn _status ->
      case Store.subject(delivery_id) do
        %{"subject_type" => type, "subject_id" => id, "message_class" => class} ->
          key = topic_key(scope.tenant_id, type, id, class)
          {key, Store.message_ref(target_id, key)}

        nil ->
          {nil, nil}
      end
    end)
  end

  # CH-23
  @doc "Keeps the provider message a delivery posted in a conversation under its subject key, in its own transaction."
  @spec remember(Scope.t(), Relay.Id.t(), <<_::256>> | nil, String.t() | nil, Relay.Id.t()) ::
          result(:recorded | :target_not_found | :skipped)
  def remember(_scope, _target_id, key, ref, _delivery_id) when is_nil(key) or is_nil(ref),
    do: {:ok, :skipped}

  def remember(%Scope{} = scope, target_id, key, ref, delivery_id) do
    Store.in_scope(scope, fn _status -> Store.message_put(target_id, key, ref, delivery_id) end)
  end

  # CH-62
  @doc """
  Starts an installation of a channel identity in a workspace. Slack and Discord answer the provider's authorize address with a sealed `state`; the provider sends the user back to `redirect_uri`, which hands the `code` and `state` to `complete_install/3`. Telegram registers the bot's webhook at once and answers the installation. `base_url` is Relay's public address, under which the inbound endpoint is reached.
  """
  @spec start_install(Scope.t(), map(), String.t(), Relay.Actor.t(), keyword()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def start_install(%Scope{} = scope, attrs, base_url, actor, opts \\ []) do
    channel = attrs.channel

    with {:ok, identity} <- identity(scope, attrs.identity_id, channel) do
      if channel in @oauth,
        do: authorize(scope, attrs, identity, actor),
        else: telegram(scope, identity, base_url, actor, opts)
    end
  end

  defp authorize(scope, attrs, identity, actor) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    sealed = %{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      channel: attrs.channel,
      identity_id: identity.id,
      redirect_uri: attrs.redirect_uri,
      actor_ref: actor.ref
    }

    case Install.seal(sealed, now) do
      {:ok, state} ->
        url = Install.authorize_url(attrs.channel, identity.app_ref, attrs.redirect_uri, state)

        {:ok,
         %{
           state: "pending",
           channel: attrs.channel,
           authorize_url: url,
           expires_at: DateTime.from_unix!(now + Install.lifetime_s())
         }}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp telegram(scope, identity, base_url, actor, opts) do
    url = inbound_url(base_url, scope, "telegram", identity.id)

    case Install.telegram(identity, url, Install.telegram_secret(identity), opts) do
      {:ok, installed} ->
        account(scope, "telegram", identity, installed, identity.secret_ref_id, actor)

      {:error, reason} ->
        {:error, install_failed(reason)}
    end
  end

  # CH-62
  @doc "The address at which a channel identity's provider delivers its inbound requests."
  @spec inbound_url(String.t(), Scope.t(), String.t(), Relay.Id.t()) :: String.t()
  def inbound_url(base_url, %Scope{} = scope, channel, identity_id) do
    Enum.join(
      [
        String.trim_trailing(base_url, "/"),
        "inbound/v1",
        channel,
        Relay.ExternalId.encode("ten", scope.tenant_id),
        Relay.Environment.dump(scope.environment),
        Relay.ExternalId.encode("chi", identity_id)
      ],
      "/"
    )
  end

  # CH-62
  # TN-26
  @doc "Completes a Slack or Discord installation from the provider's redirect: unseals the `state`, exchanges the `code`, stores the Slack bot token in the key store and records the workspace's provider account as verified."
  @spec complete_install(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def complete_install(state, code, opts \\ []) when is_binary(state) and is_binary(code) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    with {:ok, sealed} <- unseal(state, now),
         {:ok, scope} <- Scope.new(sealed.tenant_id, sealed.environment),
         {:ok, actor} <- Relay.Actor.new(:system, sealed.actor_ref, sealed.actor_ref),
         {:ok, identity} <- identity(scope, sealed.identity_id, sealed.channel),
         {:ok, installed} <- exchange(sealed, identity, code, opts),
         {:ok, credential_id} <- credential(scope, sealed.channel, identity, installed, actor) do
      account(scope, sealed.channel, identity, installed, credential_id, actor)
    end
  end

  defp unseal(state, now) do
    case Install.unseal(state, now) do
      {:ok, sealed} when sealed.channel in @oauth -> {:ok, sealed}
      _invalid -> {:error, state_invalid()}
    end
  end

  defp exchange(sealed, identity, code, opts) do
    case Install.exchange(sealed.channel, identity, code, sealed.redirect_uri, opts) do
      {:ok, installed} -> {:ok, installed}
      {:error, reason} -> {:error, install_failed(reason)}
    end
  end

  defp credential(_scope, _channel, identity, %{token: nil}, _actor),
    do: {:ok, identity.secret_ref_id}

  defp credential(scope, channel, _identity, %{token: token}, actor) do
    id = Relay.Id.generate()
    label = Enum.join(["relay", channel, Scope.tenant_text(scope), Relay.Id.to_string(id)], "-")

    attrs = %{
      id: id,
      kind: :provider_credential,
      ref: Relay.Keys.uri(label),
      ref_version: 1,
      record_digest: digest(scope, "secret_ref.registered", actor, "secret_ref", id, nil)
    }

    with :ok <- Relay.Keys.store_secret(label, token),
         {:ok, _registered} <- Relay.Secrets.register(scope, attrs, actor) do
      {:ok, id}
    else
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp account(scope, channel, identity, installed, credential_id, actor) do
    with {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, declaration} <- ChannelDeclarations.declaration(declarations, channel),
         {:ok, id} <-
           put_account(scope, channel, identity, {installed, credential_id}, declaration, actor),
         {:ok, _verified} <- verify(scope, id, actor) do
      _ = announce(scope, channel, id, installed.workspace, declaration)
      {:ok, %{state: "installed", channel: channel, provider_account_id: id}}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _failed -> {:error, unavailable()}
    end
  end

  defp put_account(scope, channel, identity, {installed, credential_id}, declaration, actor) do
    existing =
      Store.in_scope(scope, fn _status ->
        Store.installation(channel, identity.id, installed.workspace)
      end)

    id =
      case existing do
        {:ok, %{"id" => id}} -> id
        _new -> Relay.Id.generate()
      end

    residency = declaration["data_residency"]

    settings =
      Map.merge(installed.settings, %{
        "identity_id" => Relay.Id.to_string(identity.id),
        "workspace_id" => installed.workspace
      })

    attrs = %{
      id: id,
      channel: channel,
      provider: channel,
      ownership: "tenant",
      credential_ref_id: credential_id,
      role: "primary",
      priority: 0,
      in_installation: residency["in_installation"],
      processing_countries: residency["processing_countries"],
      transfer_basis: residency["transfer_basis"],
      scc_notified_on: residency["scc_notified_on"],
      settings: settings
    }

    digest = digest(scope, "provider_account.changed", actor, "provider_account", id, "created")

    case Relay.Channels.put_account(scope, attrs, digest, actor) do
      {:ok, {result, _version}} when result in [:created, :updated, :unchanged] -> {:ok, id}
      {:ok, {_refused, _version}} -> {:error, unavailable()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp verify(scope, id, actor) do
    digest = digest(scope, "provider_account.verified", actor, "provider_account", id, "verified")
    Relay.Channels.verify_account(scope, id, "verified", nil, digest, actor)
  end

  # CH-62
  # CH-4
  defp announce(scope, channel, account_id, workspace, declaration) do
    Store.in_scope(scope, fn _status ->
      payload = %{
        "channel" => channel,
        "provider_account_id" => Relay.Id.to_string(account_id),
        "workspace_id" => workspace
      }

      stream = "messaging:" <> channel
      :appended = Store.event("messaging_installation.completed", stream, payload)

      for deprecation <- List.wrap(declaration["deprecations"]),
          do: Store.event("channel_adapter.deprecated", stream, warning(declaration, deprecation))

      :ok
    end)
  end

  defp warning(declaration, deprecation) do
    %{
      "provider" => declaration["provider"],
      "adapter_version" => declaration["adapter_version"],
      "api" => deprecation["api"],
      "sunset_on" => deprecation["sunset_on"]
    }
  end

  defp identity(scope, id, channel) do
    kind = Map.fetch!(@kinds, channel)

    with {:ok, %{"kind" => ^kind, "state" => "active"} = row} <-
           Store.in_scope(scope, fn _status -> Store.identity(id) end),
         {:ok, secret} <- Relay.Secrets.fetch(scope, row["secret_ref_id"]) do
      {:ok,
       %{
         id: row["id"],
         app_ref: row["app_ref"],
         secret_ref_id: row["secret_ref_id"],
         secret: secret
       }}
    else
      {:ok, _missing} -> {:error, identity_not_found()}
      {:error, %Relay.Error{code: :not_found}} -> {:error, identity_not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp digest(scope, action, actor, target_type, target_id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: target_type,
      target_id: Relay.Id.to_string(target_id),
      reason: reason
    })
  end

  # CH-62
  # WH-49
  # T-40
  @doc """
  Accepts an inbound request of a channel identity: the signature is verified on the raw body first; a provider handshake (Slack's URL verification, Discord's `PING`) is answered at once; an event is committed as a receipt with its processing job before the answer, and a repeated provider event is acknowledged without being processed again. Returns the HTTP status and the JSON body the provider expects, or why the request is refused.
  """
  @spec accept(map(), keyword()) ::
          {:ok, 200, map()} | {:error, :not_found | :unauthorized | :unavailable}
  def accept(%{channel: channel} = request, opts \\ []) when channel in @channels do
    now = Relay.Clock.utc_now()

    with {:ok, scope} <- Scope.new(request.tenant_id, request.environment),
         {:ok, identity} <- inbound_identity(scope, request.identity_id, channel),
         :ok <- authenticate(channel, identity, request, now, opts) do
      case Inbound.parse(channel, request.raw, request.content_type) do
        {:reply, body} -> {:ok, 200, body}
        :ignored -> {:ok, 200, %{}}
        {:event, event, reply} -> record(scope, channel, identity, request.raw, event, reply)
      end
    end
  end

  defp inbound_identity(scope, id, channel) do
    case identity(scope, id, channel) do
      {:ok, identity} -> {:ok, identity}
      {:error, %Relay.Error{code: :channel_identity_not_found}} -> {:error, :not_found}
      {:error, _error} -> {:error, :unavailable}
    end
  end

  defp authenticate("teams", identity, request, now, opts) do
    service_url =
      case Jason.decode(request.raw) do
        {:ok, %{"serviceUrl" => url}} -> url
        _other -> nil
      end

    case TeamsAuth.verify(request.authorization, identity.app_ref, service_url, now, opts) do
      :ok -> :ok
      {:error, :keys_unavailable} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp authenticate(channel, identity, request, now, _opts) do
    case Inbound.verify(channel, identity.secret, request.raw, request.headers, now) do
      :ok -> :ok
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp record(scope, channel, identity, raw, event, reply) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         field = receipt_field(scope, key_id),
         {:ok, body_ct} <- Relay.Tenancy.encrypt_field(field, raw),
         {:ok, _result} <- commit(scope, channel, identity, raw, event, body_ct, key_id) do
      {:ok, 200, reply || %{}}
    else
      _failed -> {:error, :unavailable}
    end
  end

  defp commit(scope, channel, identity, raw, event, body_ct, key_id) do
    receipt = %{
      id: Relay.Id.generate(),
      provider: channel,
      provider_event_id: String.slice(event.event_id, 0, 512),
      body_digest: :crypto.hash(:sha256, raw),
      body_ct: body_ct,
      body_key_id: key_id
    }

    Store.in_scope(scope, fn _status ->
      case Relay.Webhooks.receipt_record(receipt) do
        {:recorded, id} -> enqueue(scope, id, identity.id)
        {:duplicate, _id} -> :duplicate
      end
    end)
  end

  defp enqueue(scope, receipt_id, identity_id) do
    job = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: Relay.Messaging.InboundWorker,
      args:
        scope
        |> Scope.to_job_args()
        |> Map.merge(%{
          "receipt_id" => Relay.Id.to_string(receipt_id),
          "identity_id" => Relay.Id.to_string(identity_id)
        }),
      ref_kind: "webhook_receipt",
      ref_id: receipt_id
    }

    case Relay.Platform.enqueue_job(job) do
      {:ok, _queued} -> :recorded
      {:error, error} -> Store.rollback(error)
    end
  end

  defp receipt_field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      table: "webhook_receipts",
      column: "body_ct",
      key_id: key_id
    }
  end

  # CH-62
  # WH-49
  # INV-29
  @doc """
  Processes an inbound receipt (the `Relay.Messaging.InboundWorker` job): reads the event again from the sealed body, finds the delivery whose message it refers to, records a Teams installation from the bot's installation update, appends `messaging_interaction.received` and marks the receipt processed. Nothing here approves anything: an approval is given only on the Access approval surface.
  """
  @spec process(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def process(%Scope{} = scope, receipt_id, identity_id) do
    with {:ok, %{"state" => "received"} = receipt} <-
           Store.in_scope(scope, fn _status -> Relay.Webhooks.receipt(receipt_id) end),
         field = receipt_field(scope, receipt["body_key_id"]),
         {:ok, raw} <- Relay.Tenancy.decrypt_field(field, receipt["body_ct"]),
         channel = receipt["provider"],
         body = Redacted.expose(raw),
         {:event, event, _reply} <- Inbound.parse(channel, body, content_type(body)) do
      account_id = installed(scope, channel, identity_id, event)
      interaction(scope, receipt_id, channel, account_id, event)
    else
      {:ok, _final_or_missing} -> :ok
      {:error, reason} -> {:error, reason}
      _unreadable -> mark(scope, receipt_id, :rejected, "unreadable")
    end
  end

  defp content_type("payload=" <> _rest), do: "application/x-www-form-urlencoded"
  defp content_type(_json), do: "application/json"

  defp installed(scope, "teams", identity_id, %{kind: "conversation", workspace: tenant} = event)
       when is_binary(tenant) do
    installed = %{workspace: tenant, token: nil, settings: %{}}
    lookup = fn _status -> Store.installation("teams", identity_id, tenant) end

    with {:ok, nil} <- Store.in_scope(scope, lookup),
         "installationUpdate" <- event.action,
         {:ok, actor} <- Relay.Actor.new(:system, "relay-messaging", "relay-messaging"),
         {:ok, identity} <- identity(scope, identity_id, "teams"),
         {:ok, %{provider_account_id: id}} <-
           account(scope, "teams", identity, installed, identity.secret_ref_id, actor) do
      id
    else
      {:ok, %{"id" => id}} -> id
      _other -> nil
    end
  end

  defp installed(scope, channel, identity_id, %{workspace: workspace})
       when is_binary(workspace) do
    case Store.in_scope(scope, fn _ -> Store.installation(channel, identity_id, workspace) end) do
      {:ok, %{"id" => id}} -> id
      _none -> nil
    end
  end

  defp installed(_scope, _channel, _identity_id, _event), do: nil

  defp interaction(scope, receipt_id, channel, account_id, event) do
    result =
      Store.in_scope(scope, fn _status ->
        delivery_id =
          if is_binary(account_id) and is_binary(event[:message_ref]),
            do: Store.message_delivery(account_id, event.message_ref)

        payload = payload(channel, account_id, delivery_id, event)
        stream = "messaging:" <> channel
        :appended = Store.event("messaging_interaction.received", stream, payload)
        Relay.Webhooks.receipt_mark(receipt_id, :processed, nil)
      end)

    case result do
      {:ok, _marked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload(channel, account_id, delivery_id, event) do
    fields = %{
      "channel" => channel,
      "kind" => event.kind,
      "provider_event_id" => event.event_id,
      "provider_account_id" => uuid(account_id),
      "delivery_id" => uuid(delivery_id),
      "provider_user_id" => event[:user],
      "conversation_id" => event[:conversation],
      "action" => event[:action],
      "text" => event[:text],
      "conversation_reference" => event[:reference]
    }

    Map.reject(fields, fn {_key, value} -> is_nil(value) end)
  end

  defp uuid(<<_::128>> = id), do: Relay.Id.to_string(id)
  defp uuid(_none), do: nil

  defp mark(scope, receipt_id, state, reason) do
    case Relay.Webhooks.mark_receipt(scope, receipt_id, state, reason) do
      {:ok, _marked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # CH-4
  @doc "Every registered messaging and other adapter with its version, whether it receives traffic, the deprecated provider APIs it uses and whether the scope uses the provider, so a tenant sees the warning."
  @spec adapters(Scope.t()) :: result([map()])
  def adapters(%Scope{} = scope) do
    with {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, used} <- Store.in_scope(scope, fn _status -> Store.providers() end) do
      {:ok,
       for status <- Relay.Channels.adapter_status(declarations), status.provider != "fake" do
         {:ok, declaration} = ChannelDeclarations.declaration(declarations, status.provider)
         deprecations = List.wrap(declaration["deprecations"])

         %{
           provider: status.provider,
           channels: status.channels,
           adapter_version: declaration["adapter_version"],
           activated: status.activated,
           in_use: status.provider in used,
           deprecations: deprecations,
           warning: deprecations != [] and status.provider in used
         }
       end}
    end
  end

  defp state_invalid,
    do: Relay.Error.new(:messaging_install_state_invalid, "the installation state is not valid")

  defp identity_not_found do
    message = "no channel identity of this channel has this id"
    Relay.Error.new(:channel_identity_not_found, message)
  end

  defp install_failed(reason) do
    Relay.Error.new(:messaging_install_failed, "the provider refused the installation", %{
      provider_error: String.slice(to_string(reason), 0, 128)
    })
  end

  defp unavailable do
    Relay.Error.new(:service_unavailable, "the messaging channel could not be reached", %{
      retry_after: 1
    })
  end
end
