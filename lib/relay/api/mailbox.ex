defmodule Relay.Api.Mailbox do
  @moduledoc """
  The agent face of the mailbox on the server API (AG-20, AG-21, AG-22, AG-24, AG-64; `Relay.Agents`): the caller's own mailbox, lease and acknowledgement of its records, reading them in order after a position, one record by its durable handle and the dead letter view.

  The owner is the credential's: an API client owns the mailbox `(tenant, environment, api_client)`, opened lazily by its first call (AG-64). An agent credential owns the mailbox of its agent record; until a credential names its agent record, such a credential is answered `agent_not_found` and never falls back to an API client's mailbox. A caller reads and acknowledges only its own mailbox; a credential with the `read` scope also reads a record and the dead letters of any agent or API client mailbox of its environment, which is how the owner of an agent follows `mailbox.record_dead_lettered`.

  A lease request above the contract's `mailbox.lease_max_records` is refused with the limit, its name and the value in the error (AG-53). The outcome of an acknowledgement is a result for each record, never an error.

  A record carries its structured message for the owner of its mailbox (C-76, AG-39, AG-40; `Relay.Agents.mailbox_messages/3`): the signed CloudEvents envelope with the typed fields and the content parts of the record, and the trust label of a message (AG-38). The content is opened and the envelope signed outside any transaction, so a lease commits first and its messages are built after it. A reader that is not the owner gets the record without its message, and the dead letter view lists records without their messages: the message of a dead letter is read by its handle.
  """

  alias Relay.Agents
  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @typedoc "Who calls: the API client identifier of the credential, whether the credential is an agent's, and its granted scopes."
  @type caller :: %{
          required(:api_client_id) => String.t() | nil,
          required(:agent) => boolean(),
          optional(:agent_id) => Relay.Id.t() | nil,
          required(:scopes) => [String.t()]
        }

  @read_default 50
  @read_max 100

  # AG-20
  # AG-64
  @doc "The caller's mailbox, opened if it has none."
  @spec get(Scope.t(), caller()) :: answer()
  def get(%Scope{} = scope, caller) do
    with {:ok, owner} <- owner(caller) do
      case Agents.mailbox(scope, owner) do
        {:ok, mailbox} -> {:ok, {200, [], view(mailbox, message_key(scope))}}
        {:error, reason} -> {:error, refused(reason)}
      end
    end
  end

  # AG-40
  defp message_key(scope) do
    case Agents.mailbox_message_key(scope) do
      {:ok, key} -> key
      {:error, _error} -> nil
    end
  end

  # AG-20
  # AG-22
  # AG-53
  # AG-40
  @doc "Leases records of the caller's mailbox in a transaction of its own and builds their messages after it. The message key is read first, so a key store that cannot sign refuses the request before a record is taken."
  @spec lease(Scope.t(), caller(), map() | nil) :: answer()
  def lease(%Scope{} = scope, caller, body) do
    with {:ok, owner} <- owner(caller),
         {:ok, max} <- lease_max(body),
         {:ok, _key} <- signing(scope),
         {:ok, lease} <- leased(scope, owner, max),
         {:ok, messages} <- messages(scope, lease.records, :inline) do
      {:ok, {200, [], lease_view(lease, messages)}}
    end
  end

  defp signing(scope) do
    with {:error, _error} <- Agents.mailbox_message_key(scope), do: {:error, unavailable()}
  end

  defp leased(scope, owner, max) do
    case Agents.lease_mailbox(scope, owner, max) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, refused(reason)}
    end
  end

  # C-76
  # AG-40
  defp messages(scope, records, include) do
    case Agents.mailbox_messages(scope, records, include) do
      {:ok, messages} -> {:ok, messages}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp lease_max(body) do
    limit = Agents.mailbox_limits().lease_max_records

    case (body || %{})["max"] do
      nil ->
        {:ok, 1}

      max when is_integer(max) and max >= 1 and max <= limit ->
        {:ok, max}

      max ->
        detail = "one lease request takes at most #{limit} records"

        details = %{
          errors: [%{pointer: "/max", code: "too_long", detail: detail}],
          limit: limit,
          actual: max,
          limit_name: "mailbox.lease_max_records"
        }

        {:error, Relay.Error.new(:validation_failed, "the request breaks a field rule", details)}
    end
  end

  # AG-20
  @doc "Acknowledges records of one lease of the caller's mailbox inside the request's transaction."
  @spec ack(caller(), map()) :: answer()
  def ack(caller, %{"lease_id" => lease_id, "record_ids" => texts}) do
    ids = Enum.map(texts, &record_id/1)
    known = for {:ok, id} <- ids, do: id

    with {:ok, owner} <- owner(caller),
         {:ok, acked} <- acked(owner, lease_id, known) do
      {:ok, {200, [], ack_view(Enum.zip(texts, ids), acked)}}
    end
  end

  defp acked(owner, lease_id, ids) do
    case Agents.ack_mailbox_in(owner, lease_id, ids) do
      {:ok, acked} -> {:ok, acked}
      {:error, reason} -> {:error, refused(reason)}
    end
  end

  defp ack_view(named, %{results: results, acked: acked}) do
    results = Map.new(results)
    rows = for {text, id} <- named, do: %{"record_id" => text, "result" => result(id, results)}
    %{"object" => "mailbox_ack", "results" => rows, "acked_cursor" => cursor(acked)}
  end

  defp record_id(text), do: Relay.ExternalId.decode(text, ["mbr"])

  defp result({:ok, id}, results), do: results |> Map.fetch!(id) |> Atom.to_string()
  defp result({:error, _error}, _results), do: "not_found"

  # AG-20
  # AG-24
  @doc "Reads the records of the caller's mailbox after `since`, or after the acknowledged position."
  @spec read(Scope.t(), caller(), map()) :: answer()
  def read(%Scope{} = scope, caller, query) do
    with {:ok, owner} <- owner(caller),
         {:ok, since} <- since(query["since"]),
         {:ok, limit} <- limit(query["limit"]) do
      case Agents.read_mailbox(scope, owner, since, limit) do
        {:ok, page} -> page_view(scope, page)
        {:resync_required, position} -> {:ok, {200, [], resync_view(position)}}
        {:error, reason} -> {:error, refused(reason)}
      end
    end
  end

  defp page_view(scope, page) do
    with {:ok, messages} <- messages(scope, page.records, :inline) do
      view = records_view(page.records, messages, page.position, page.has_more, false)
      {:ok, {200, [], view}}
    end
  end

  defp resync_view(position), do: records_view([], %{}, position, false, true)

  defp since(nil), do: {:ok, nil}

  defp since(text) do
    case Relay.Inbox.decode_cursor(text) do
      {:ok, %{epoch: epoch, seq: seq}} -> {:ok, %{epoch: epoch, seq: seq}}
      :error -> {:error, Gate.field_error("/since", "invalid_format", "a cursor of the mailbox")}
    end
  end

  defp limit(nil), do: {:ok, @read_default}

  defp limit(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..@read_max -> {:ok, n}
      _invalid -> {:error, limit_error()}
    end
  end

  defp limit(_other), do: {:error, limit_error()}

  defp limit_error,
    do: Gate.field_error("/limit", "invalid_format", "an integer, 1 to #{@read_max}")

  # AG-21
  # AG-40
  # AG-68
  @doc "Reads one record by its durable handle: one of the caller's mailbox with its message, or any of the environment, without a message, for a credential with the `read` scope. `content=referenced` resolves the references of the message."
  @spec record(Scope.t(), caller(), Relay.Id.t(), map()) :: answer()
  def record(%Scope{} = scope, caller, record_id, query \\ %{}) do
    with {:ok, include} <- include(query["content"]) do
      case own_record(scope, caller, record_id) do
        {:ok, %{} = record} -> owned_view(scope, record, include)
        {:ok, nil} -> any_record(scope, caller, record_id)
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  defp owned_view(scope, record, include) do
    with {:ok, messages} <- messages(scope, [record], include),
         do: {:ok, {200, [], record_view(record, messages)}}
  end

  defp include(nil), do: {:ok, :inline}
  defp include("inline"), do: {:ok, :inline}
  defp include("referenced"), do: {:ok, :referenced}

  defp include(_other),
    do: {:error, Gate.field_error("/content", "invalid_format", "inline or referenced")}

  defp own_record(scope, caller, record_id) do
    case owner(caller) do
      {:ok, owner} -> Agents.mailbox_record(scope, record_id, owner)
      {:error, _error} -> {:ok, nil}
    end
  end

  defp any_record(scope, %{scopes: scopes}, record_id) do
    with true <- "read" in scopes,
         {:ok, %{} = record} <- Agents.mailbox_record(scope, record_id, :any) do
      {:ok, {200, [], record_view(record, %{})}}
    else
      {:error, _reason} -> {:error, unavailable()}
      _none -> {:error, record_not_found()}
    end
  end

  # AG-22
  # AG-23
  # API-56
  @doc "Lists the dead-lettered records of the caller's mailbox, or of the mailbox `mailbox_id` names for a credential with the `read` scope; newest first."
  @spec dead_letters(Scope.t(), caller(), map(), Pagination.page(), String.t()) :: answer()
  def dead_letters(%Scope{} = scope, caller, query, page, endpoint) do
    with {:ok, whose} <- target(scope, caller, query["mailbox_id"]) do
      case Agents.mailbox_dead_letters(scope, whose, page.cursor, page.limit) do
        {:ok, rows} -> listed(rows, page, scope, endpoint)
        {:error, reason} -> {:error, refused(reason)}
      end
    end
  end

  defp listed(rows, page, scope, endpoint) do
    position = &{&1["created_at"], &1["id"]}
    view = &record_view(&1, %{})

    with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, position),
         do: {:ok, {200, [], body}}
  end

  defp target(_scope, caller, nil), do: owner(caller)

  defp target(scope, %{scopes: scopes} = caller, text) do
    case Relay.ExternalId.decode(text, ["mbx"]) do
      {:ok, mailbox_id} ->
        if "read" in scopes, do: {:ok, {:id, mailbox_id}}, else: own(scope, caller, mailbox_id)

      {:error, _error} ->
        {:error, Gate.field_error("/mailbox_id", "invalid_format", "a mailbox identifier")}
    end
  end

  defp own(scope, caller, mailbox_id) do
    with {:ok, owner} <- owner(caller),
         {:ok, %{id: ^mailbox_id}} <- Agents.mailbox(scope, owner) do
      {:ok, owner}
    else
      _other ->
        message = "another mailbox is read with the read scope"
        {:error, Relay.Error.new(:auth_insufficient_scope, message, %{required_scope: "read"})}
    end
  end

  # AG-6
  # E-29
  defp owner(%{agent: true, agent_id: <<_::128>> = id}), do: {:ok, {:agent, id}}

  defp owner(%{agent: true}) do
    {:error, Relay.Error.new(:agent_not_found, "the credential names no agent record")}
  end

  defp owner(%{api_client_id: text}) do
    case Relay.ExternalId.decode(text, ["cli"]) do
      {:ok, id} -> {:ok, {:api_client, id}}
      {:error, _error} -> {:error, not_found()}
    end
  end

  # AG-20
  @doc "The API view of a mailbox with the public key of its messages."
  @spec view(map(), String.t() | nil) :: map()
  def view(mailbox, message_key) do
    {kind, ref} = mailbox.owner
    prefix = if kind == :agent, do: "agt", else: "cli"

    %{
      "object" => "mailbox",
      "id" => Views.id("mbx", mailbox.id),
      "owner" => Views.id(prefix, ref),
      "state" => Atom.to_string(mailbox.state),
      "cursor" => cursor(mailbox.head),
      "acked_cursor" => cursor(mailbox.acked),
      "lease_duration" => "PT#{div(mailbox.settings.lease_ms, 1000)}S",
      "max_redeliveries" => mailbox.settings.max_redeliveries,
      "message_key" => message_key,
      "created_at" => mailbox.created_at
    }
  end

  # AG-21
  # AG-24
  # AG-38
  # C-76
  @doc "The API view of a mailbox record: its handle, its position, its delivery state, the trust label of a message and its message out of `messages`, or none."
  @spec record_view(map(), map()) :: map()
  def record_view(record, messages) do
    message = Map.get(messages, record["id"], %{})

    %{
      "object" => "mailbox_record",
      "id" => Views.id("mbr", record["id"]),
      "mailbox_id" => Views.id("mbx", record["mailbox_id"]),
      "epoch" => record["epoch"],
      "seq" => record["seq"],
      "kind" => record["kind"],
      "event_type" => record["event_type"],
      "waitpoint_id" => Views.id("wp", record["waitpoint_id"]),
      "trust_label" => record["trust_label"] || message["trust_label"],
      "message" => message["message"],
      "payload_digest" => "sha256:" <> Gate.hex(record["payload_digest"]),
      "state" => record["delivery_state"],
      "delivery_count" => record["delivery_count"],
      "lease_expires_at" => record["lease_until"],
      "acked_at" => record["acked_at"],
      "dead_lettered_at" => record["dead_lettered_at"],
      "created_at" => record["created_at"]
    }
  end

  defp lease_view(lease, messages) do
    %{
      "object" => "mailbox_lease",
      "lease_id" => lease.lease_id,
      "lease_expires_at" => lease.lease_until,
      "records" => Enum.map(lease.records, &record_view(&1, messages))
    }
  end

  defp records_view(records, messages, position, has_more, resync) do
    %{
      "object" => "mailbox_records",
      "records" => Enum.map(records, &record_view(&1, messages)),
      "cursor" => cursor(position),
      "has_more" => has_more,
      "resync_required" => resync
    }
  end

  defp cursor(%{epoch: epoch, seq: seq}), do: Relay.Inbox.encode_cursor(%{epoch: epoch, seq: seq})

  defp refused(:inactive),
    do: Relay.Error.new(:mailbox_inactive, "the mailbox is suspended and hands out no lease")

  defp refused(reason) when reason in [:not_found, :owner_not_found], do: not_found()

  defp refused(:tenant_inactive),
    do: Relay.Error.new(:tenant_inactive, "the tenant is not active")

  defp refused(_reason), do: unavailable()

  defp not_found, do: Relay.Error.new(:mailbox_not_found, "no such mailbox")
  defp record_not_found, do: Relay.Error.new(:mailbox_record_not_found, "no such record")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "the mailbox cannot be read now")
end
