defmodule Relay.Api.MailboxMessages do
  @moduledoc """
  Messages between agents on the server API (AG-56 … AG-61, AG-67, AG-73, AG-74; `Relay.Agents`): sending an end-to-end encrypted envelope to another agent's mailbox, the request box, reading an envelope, the block list and the abuse report. Every operation is the calling agent's own: the sender of a message and the owner of a mailbox is the agent record the credential's Access identity is bound to.

  `prepare/4` runs before the request's transaction. It checks that this installation's region carries encrypted envelopes (the active `encrypted_transport` data set, AG-74), decodes the envelope and holds it to the contract's `encrypted_envelope.max_bytes` (AG-57), verifies a first-contact token against the issuer's token keys, which come from Access's issuer directory and are read again once for a key the kept directory does not list (AG-73), and seals the envelope at rest under the tenant's data key. Relay never opens the envelope and derives nothing from it (AG-56). `send/1` runs inside the request's transaction, where the relationship level, the block list, the first-contact rate and the spent tokens decide where the message goes. Its answer is the same whatever box the message went to, so a blocked sender learns nothing (AG-61).
  """

  alias Relay.Agents
  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @dataset "encrypted_transport"
  @marking "encrypted_untrusted_content"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @typedoc "Who calls: whether the credential is an agent's, its agent record and its API client identifier."
  @type caller :: %{
          required(:agent) => boolean(),
          required(:agent_id) => Relay.Id.t() | nil,
          optional(:api_client_id) => String.t() | nil,
          optional(:scopes) => [String.t()]
        }

  # AG-56
  # AG-57
  # AG-60
  # AG-73
  # AG-74
  @doc "Prepares a message before the request's transaction: the sender, the recipient, the envelope within its size limit and sealed at rest, and the first-contact token as it verified."
  @spec prepare(Scope.t(), caller(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, caller, body, traceparent) do
    %{"to" => to, "encrypted_envelope" => envelope} = body

    with {:ok, sender_id} <- agent(caller),
         {:ok, recipient_id} <- recipient(to),
         :ok <- carried(),
         {:ok, bytes} <- ciphertext(envelope["ciphertext"]),
         {:ok, key_id, sealed} <- seal(scope, bytes) do
      {:ok,
       %{
         id: Relay.Id.generate(),
         recipient_id: recipient_id,
         sender_id: sender_id,
         content_encryption: envelope["content_encryption"],
         size: byte_size(bytes),
         payload_ct: sealed,
         payload_tenant_key_id: key_id,
         payload_digest: :crypto.hash(:sha256, bytes),
         token: token(body["first_contact_token"]),
         traceparent: traceparent
       }}
    end
  end

  defp recipient(text) do
    case Relay.ExternalId.decode(text, ["agt"]) do
      {:ok, id} ->
        {:ok, id}

      {:error, _error} ->
        {:error, Gate.field_error("/to", "invalid_format", "an agent identifier")}
    end
  end

  # AG-58
  # AG-74
  defp carried do
    region = Relay.Datasets.installation_region()

    content =
      if region == "eu" do
        case Relay.Datasets.active(Relay.Datasets.installation_scope(), @dataset) do
          {:ok, %{content: %{} = content}} -> content
          _none -> nil
        end
      end

    case Agents.encrypted_transport(region, content) do
      :enabled ->
        :ok

      :disabled ->
        message = "this installation's region does not carry encrypted envelopes"
        {:error, Relay.Error.new(:encrypted_transport_disabled, message)}
    end
  end

  # AG-57
  # AG-53
  defp ciphertext(text) do
    limit = Agents.message_limits().envelope_max_bytes

    case Base.decode64(text) do
      {:ok, bytes} when byte_size(bytes) <= limit ->
        {:ok, bytes}

      {:ok, bytes} ->
        details = %{
          errors: [
            %{
              pointer: "/encrypted_envelope/ciphertext",
              code: "too_long",
              detail: "an envelope is at most #{limit} bytes"
            }
          ],
          limit: limit,
          actual: byte_size(bytes),
          limit_name: "encrypted_envelope.max_bytes"
        }

        {:error, Relay.Error.new(:validation_failed, "the request breaks a field rule", details)}

      :error ->
        {:error, Gate.field_error("/encrypted_envelope/ciphertext", "invalid_format", "base64")}
    end
  end

  # AG-60
  # AG-73
  defp token(nil), do: :none

  defp token(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, bytes} -> verified(bytes)
      :error -> :invalid
    end
  end

  defp verified(bytes) do
    with :invalid <- Agents.first_contact_token(bytes, issuer(false)) do
      Agents.first_contact_token(bytes, issuer(true))
    end
  end

  defp issuer(again) do
    read =
      if again,
        do: Relay.Access.refresh_first_contact_issuer(),
        else: Relay.Access.first_contact_issuer()

    case read do
      {:ok, issuer} -> issuer
      :unconfigured -> nil
    end
  end

  defp seal(scope, bytes) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, sealed} <- Relay.Tenancy.encrypt_field(field(scope, key_id), bytes) do
      {:ok, key_id, sealed}
    else
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "mailbox_records",
      column: "payload_ct",
      key_id: key_id
    }
  end

  # AG-56
  # AG-59
  # AG-60
  # AG-61
  @doc "Sends a prepared message inside the request's transaction."
  @spec send(map()) :: answer()
  def send(message) do
    case Agents.send_message_in(message) do
      {:ok, sent} -> {:ok, {202, [], receipt(sent.id)}}
      {:error, refusal} -> {:error, refused(refusal)}
    end
  end

  defp receipt(id) do
    %{
      "object" => "mailbox_message_receipt",
      "id" => Views.id("mbr", id),
      "created_at" => Relay.Clock.utc_now()
    }
  end

  defp refused(:self),
    do: Gate.field_error("/to", "not_allowed", "an agent other than the sender")

  defp refused(reason) when reason in [:sender_not_found, :recipient_not_found],
    do: Relay.Error.new(:agent_not_found, "no such agent")

  defp refused(:recipient_inactive),
    do: Relay.Error.new(:mailbox_inactive, "the recipient's mailbox is suspended")

  defp refused(:token_required) do
    message = "a first contact needs an unspent first-contact token"
    Relay.Error.new(:first_contact_token_required, message)
  end

  defp refused({:rate_limited, details}),
    do: Relay.Error.new(:rate_limited, "the sender is at its first-contact limit", details)

  # AG-59
  # API-56
  @doc "Lists the request box of the caller's mailbox, newest first."
  @spec requests(Scope.t(), caller(), Pagination.page(), String.t()) :: answer()
  def requests(%Scope{} = scope, caller, page, endpoint) do
    with {:ok, agent_id} <- agent(caller) do
      case Agents.mailbox_requests(scope, agent_id, page.cursor, page.limit) do
        {:ok, rows} -> listed(rows, page, scope, endpoint)
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  defp listed(rows, page, scope, endpoint) do
    position = &{&1["created_at"], &1["record_id"]}

    with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &message_view/1, position),
         do: {:ok, {200, [], body}}
  end

  # AG-56
  # AG-57
  # AG-67
  @doc "Reads a message of the caller's mailbox with its envelope as it was sent."
  @spec envelope(Scope.t(), caller(), map()) :: answer()
  def envelope(%Scope{} = scope, caller, query) do
    with {:ok, agent_id} <- agent(caller),
         {:ok, record_id} <- record_id(query["record_id"], "/record_id") do
      case Agents.message_envelope(scope, agent_id, record_id) do
        {:ok, %{"box" => box} = row} when box != "blocked" ->
          {:ok, {200, [], opened(scope, row)}}

        {:ok, _none_or_blocked} ->
          {:error, record_not_found()}

        {:error, _reason} ->
          {:error, unavailable()}
      end
    end
  end

  defp record_id(text, pointer) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["mbr"]) do
      {:ok, id} ->
        {:ok, id}

      {:error, _error} ->
        {:error, Gate.field_error(pointer, "invalid_format", "a record identifier")}
    end
  end

  defp record_id(_missing, pointer),
    do: {:error, Gate.field_error(pointer, "required", "a record identifier")}

  defp opened(scope, row) do
    %{
      "object" => "mailbox_envelope",
      "message" => message_view(row),
      "ciphertext" => clear(scope, row["payload_ct"], row["payload_tenant_key_id"])
    }
  end

  defp clear(scope, <<_::8, _rest::binary>> = sealed, <<_::128>> = key_id) do
    case Relay.Tenancy.decrypt_field(field(scope, key_id), sealed) do
      {:ok, bytes} -> Base.encode64(Relay.Redacted.expose(bytes))
      {:error, _error} -> nil
    end
  end

  defp clear(_scope, _sealed, _key_id), do: nil

  # AG-67
  @doc "The API view of a message: what Relay records of it and nothing of its content."
  @spec message_view(map()) :: map()
  def message_view(row) do
    %{
      "object" => "mailbox_message",
      "id" => Views.id("mbr", row["record_id"]),
      "mailbox_id" => Views.id("mbx", row["mailbox_id"]),
      "epoch" => row["epoch"],
      "seq" => row["seq"],
      "sender" => Views.id("agt", row["sender_agent_id"]),
      "recipient" => Views.id("agt", row["recipient_agent_id"]),
      "size" => row["size"],
      "sent_at" => row["created_at"],
      "trust_label" => row["trust_label"],
      "relationship" => row["relationship"],
      "content_encryption" => row["content_encryption"],
      "content_marking" => @marking
    }
  end

  # AG-61
  @doc "Blocks a sender for the caller's mailbox or lifts the block, inside the request's transaction."
  @spec block(caller(), map()) :: answer()
  def block(caller, %{"sender" => sender, "blocked" => blocked}) do
    with {:ok, agent_id} <- agent(caller),
         {:ok, sender_id} <- sender(sender, agent_id) do
      actor_ref = Map.get(caller, :api_client_id) || "agent"

      case Agents.set_sender_block_in(agent_id, sender_id, blocked, actor_ref) do
        {:sender_not_found, nil} -> {:error, Relay.Error.new(:agent_not_found, "no such agent")}
        {_result, block} -> {:ok, {200, [], block_view(block)}}
      end
    end
  end

  defp sender(text, agent_id) do
    case Relay.ExternalId.decode(text, ["agt"]) do
      {:ok, ^agent_id} ->
        {:error, Gate.field_error("/sender", "not_allowed", "an agent other than the caller")}

      {:ok, id} ->
        {:ok, id}

      {:error, _error} ->
        {:error, Gate.field_error("/sender", "invalid_format", "an agent identifier")}
    end
  end

  defp block_view(block) do
    %{
      "object" => "mailbox_block",
      "sender" => Views.id("agt", block.sender_id),
      "state" => block.state,
      "blocked_at" => block.blocked_at,
      "lifted_at" => block.lifted_at
    }
  end

  # AG-61
  @doc "Reports a message of the caller's mailbox as abuse inside the request's transaction."
  @spec report(caller(), map()) :: answer()
  def report(caller, %{"record_id" => text} = body) do
    with {:ok, agent_id} <- agent(caller),
         {:ok, record_id} <- record_id(text, "/record_id") do
      statement = Map.get(body, "statement")

      with %{"sender_agent_id" => sender_id} <- Agents.message_in(agent_id, record_id),
           sender_ref = Views.id("agt", sender_id),
           {result, reported_at, attached} when result in [:reported, :already_reported] <-
             Agents.report_abuse_in(agent_id, record_id, sender_ref, statement) do
        {:ok, {200, [], report_view(text, reported_at, attached)}}
      else
        _not_found -> {:error, record_not_found()}
      end
    end
  end

  defp report_view(record_id, reported_at, attached) do
    %{
      "object" => "mailbox_abuse_report",
      "record_id" => record_id,
      "reported_at" => reported_at,
      "statement_attached" => attached
    }
  end

  # AG-6
  # E-29
  defp agent(%{agent: true, agent_id: <<_::128>> = id}), do: {:ok, id}

  defp agent(_caller),
    do: {:error, Relay.Error.new(:agent_not_found, "the credential names no agent record")}

  defp record_not_found, do: Relay.Error.new(:mailbox_record_not_found, "no such record")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "the mailbox cannot be served now")
end
