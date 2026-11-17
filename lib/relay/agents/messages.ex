defmodule Relay.Agents.Messages do
  @moduledoc """
  Messages in a mailbox: the delivery of an incoming message to the mailbox of an agent or an API client, and the signed envelope of every record of the agent face (C-76, C-77, AG-38, AG-39, AG-40, AG-41, AG-69).

  `deliver/3` is the one way a message of a sender enters a mailbox. It assigns the trust label from facts about the sender and the carrier (`Relay.Agents.TrustLabel`), asking the configured `Relay.Agents.SenderStanding` for the block list and the first contact rate; prepares the content as untrusted parts and filters its links against the tenant's allow list (`Relay.Agents.Message`); seals the content under the tenant's data key; and appends the record with its label and its event in one transaction. A message of a blocked sender is recorded as any other; its label and its event say what it is. The label is an outcome that is returned, never an error.

  `views/3` gives each record its message: the CloudEvents envelope around the typed data of the record, signed with the tenant's message key (`Relay.Agents.MessageSigner`). The content is opened and the envelope signed outside any transaction. A message whose content can no longer be opened has no envelope.

  The field cipher is configured as `config :relay, Relay.Agents, field_cipher: Module`, by default `Relay.Tenancy`.
  """

  alias Relay.Agents.Mailbox
  alias Relay.Agents.MailboxStore
  alias Relay.Agents.Message
  alias Relay.Agents.MessageSigner
  alias Relay.Agents.MessageStore
  alias Relay.Agents.SenderStanding
  alias Relay.Agents.TrustLabel
  alias Relay.Agents.Waitpoint

  @cipher Relay.Tenancy

  @type delivered :: %{
          record_id: Relay.Id.t(),
          trust_label: TrustLabel.t(),
          epoch: pos_integer(),
          seq: pos_integer(),
          links_withheld: non_neg_integer()
        }
  @type refusal ::
          {:invalid, [Message.issue(), ...]}
          | {:too_large, Message.too_large()}
          | :not_found
          | :owner_not_found
          | :tenant_inactive
          | :inactive
          | Relay.Error.t()

  # C-76
  # C-77
  # INV-30
  # AG-38
  # AG-39
  # AG-40
  # AG-69
  @doc """
  Delivers a message to the owner's mailbox. `input` is the message as `Relay.Agents.Message.prepare/2` takes it, with what is known of its sender and carrier: `:proof` (how the sender's identity was verified: `:access_token`, `:webhook_signature`, `:a2a`, `:dmarc_aligned`, or `nil`), `:suspended` (the sender is suspended in Access) and `:flagged` (the carrying channel or provider flagged the message as unwanted); optional `:id` and `:traceparent`.

  Returns the record with its label and position. A suspended mailbox is `:inactive`.
  """
  @spec deliver(Relay.Scope.t(), Mailbox.owner(), map()) ::
          {:ok, delivered()} | {:error, refusal() | term()}
  def deliver(%Relay.Scope{} = scope, {kind, <<_::128>>} = owner, input)
      when kind in [:agent, :api_client] and is_map(input) do
    with {:ok, origins} <- MailboxStore.in_scope(scope, fn _status -> origins() end),
         {:ok, prepared} <- Message.prepare(input, origins),
         label = label(scope, owner, input),
         {:ok, sealed} <- seal(scope, prepared) do
      record =
        Map.merge(sealed, %{
          id: Map.get(input, :id) || Relay.Id.generate(),
          trust_label: label,
          digest: prepared.digest,
          traceparent: Map.get(input, :traceparent)
        })

      scope
      |> MailboxStore.in_scope(fn _status -> append(owner, record) end)
      |> delivered(record, prepared)
    end
  end

  defp origins, do: MessageStore.link_origins()

  # AG-69
  defp label(scope, owner, input) do
    sender = Map.get(input, :sender)
    standing = SenderStanding.impl()

    TrustLabel.assign(%{
      blocked: standing.blocked?(scope, owner, sender),
      suspended: Map.get(input, :suspended) == true,
      flagged: Map.get(input, :flagged) == true,
      over_first_contact_rate: standing.over_first_contact_rate?(scope, owner, sender),
      proof: Map.get(input, :proof)
    })
  end

  defp append(owner, record) do
    with {:ok, mailbox} <- Mailbox.open_in(owner) do
      case MessageStore.append(Map.put(record, :mailbox_id, mailbox.id)) do
        {:appended, epoch, seq} -> {:ok, {epoch, seq}}
        :mailbox_inactive -> {:error, :inactive}
        :mailbox_not_found -> {:error, :not_found}
      end
    end
  end

  defp delivered({:ok, {:ok, {epoch, seq}}}, record, prepared) do
    {:ok,
     %{
       record_id: record.id,
       trust_label: record.trust_label,
       epoch: epoch,
       seq: seq,
       links_withheld: prepared.links_withheld
     }}
  end

  defp delivered({:ok, {:error, reason}}, _record, _prepared), do: {:error, reason}
  defp delivered({:error, reason}, _record, _prepared), do: {:error, reason}

  # TN-27
  defp seal(scope, prepared) do
    with {:ok, key_id} <- cipher().active_tenant_key(scope, :data),
         {:ok, payload_ct} <- encrypt(scope, key_id, "payload_ct", prepared.payload),
         {:ok, content_ref_ct} <- encrypt(scope, key_id, "content_ref_ct", prepared.referenced) do
      {:ok, %{key_id: key_id, payload_ct: payload_ct, content_ref_ct: content_ref_ct}}
    end
  end

  defp encrypt(_scope, _key_id, _column, nil), do: {:ok, nil}

  defp encrypt(scope, key_id, column, plain),
    do: cipher().encrypt_field(field(scope, key_id, column), plain)

  defp field(scope, key_id, column) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "mailbox_records",
      column: column,
      key_id: key_id
    }
  end

  defp cipher,
    do: :relay |> Application.get_env(Relay.Agents, []) |> Keyword.get(:field_cipher, @cipher)

  # AG-40
  @doc "The published text form of the scope's message key, which verifies the signature of every message of the scope's mailboxes; see `Relay.Agents.MessageSigner.public_key/1`."
  @spec key(Relay.Scope.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def key(%Relay.Scope{} = scope) do
    with {:ok, public_key} <- MessageSigner.public_key(scope),
         do: {:ok, MessageSigner.key_text(public_key)}
  end

  # C-76
  # AG-39
  # AG-40
  # AG-41
  # E-71
  @doc """
  The view of each of `records` (rows of the agent face), by record identifier: `"trust_label"`, the label of a message record, and `"message"`, `%{"object" => "agent_message", "id" => handle, "timestamp" => second, "signature" => token, "key" => public key, "envelope" => bytes}`, or `nil` for a message whose content cannot be opened. With `:referenced` the referenced content of a message is given in full. Runs outside any transaction.
  """
  @spec views(Relay.Scope.t(), [map()], Message.include()) ::
          {:ok, %{Relay.Id.t() => map()}} | {:error, Relay.Error.t() | term()}
  def views(_scope, [], _include), do: {:ok, %{}}

  def views(%Relay.Scope{} = scope, records, include) when include in [:inline, :referenced] do
    with {:ok, public_key} <- MessageSigner.public_key(scope),
         {:ok, read} <- MailboxStore.in_scope(scope, fn _status -> read(records, include) end) do
      context = %{read: read, include: include, key: MessageSigner.key_text(public_key)}
      Enum.reduce_while(records, {:ok, %{}}, &viewed(scope, &1, context, &2))
    end
  end

  defp viewed(scope, record, context, {:ok, done}) do
    case view(scope, record, context.read, context.include, context.key) do
      {:ok, view} -> {:cont, {:ok, Map.put(done, record["id"], view)}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp read(records, include) do
    waitpoints =
      for %{"kind" => "waitpoint_event", "waitpoint_id" => id} when id != nil <- records,
          uniq: true,
          into: %{},
          do: {id, Waitpoint.read_in(id)}

    %{contents: MessageStore.contents(records, include == :referenced), waitpoints: waitpoints}
  end

  defp view(scope, %{"kind" => "waitpoint_event"} = record, read, _include, key) do
    waitpoint = Map.get(read.waitpoints, record["waitpoint_id"])
    signed(scope, record, Message.waitpoint_data(record, waitpoint), key, nil)
  end

  defp view(scope, record, read, include, key) do
    content = Map.get(read.contents, record["id"], %{})
    record = Map.put(record, "trust_label", content["trust_label"])

    with {:ok, stored} <- open(scope, content, "payload_ct"),
         {:ok, referenced} <- open(scope, content, "content_ref_ct") do
      data = Message.message_data(record, stored, referenced, include)
      signed(scope, record, data, key, record["trust_label"])
    else
      :unreadable -> {:ok, %{"message" => nil, "trust_label" => record["trust_label"]}}
    end
  end

  defp open(scope, content, column) do
    case content[column] do
      nil ->
        {:ok, nil}

      ct ->
        field = field(scope, content["payload_tenant_key_id"], column)
        opened(cipher().decrypt_field(field, ct))
    end
  end

  defp opened({:ok, plain}) do
    case Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> :unreadable
    end
  end

  defp opened({:error, _error}), do: :unreadable

  defp signed(scope, record, data, key, label) do
    id = Relay.ExternalId.encode("mbr", record["id"])
    envelope = Message.envelope(record, data)

    with {:ok, %{timestamp: timestamp, signature: signature}} <-
           MessageSigner.sign(scope, id, envelope) do
      message = %{
        "object" => "agent_message",
        "id" => id,
        "timestamp" => timestamp,
        "signature" => signature,
        "key" => key,
        "envelope" => envelope
      }

      {:ok, %{"message" => message, "trust_label" => label}}
    end
  end
end
