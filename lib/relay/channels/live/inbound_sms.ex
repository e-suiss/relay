defmodule Relay.Channels.Live.InboundSms do
  @moduledoc """
  The keyword handler of a received SMS (PC-37, PC-39, PC-61). A provider forwards the messages an account's numbers receive to the account's webhook; each becomes a durable receipt (`Relay.Channels.Live.Receipts`, `sms_in:<provider message id>`) and is applied here from the queue, independent of the provider.

  `apply_message/3` reads the keyword (`Relay.Compliance.sms_keyword/1`). A message that is no keyword, or whose sender is no active recipient of the scope, changes nothing. Otherwise, for every recipient with the sender's number:

    * a refusal keyword is a refusal notice of the source `sms_keyword` on SMS, applied at once (`Relay.Compliance.refuse/2`, INV-18), for the brand of the sender identity the message was addressed to; its scope is the compliance table's for the countries of the sender's number (`all_channel` with the channels the row names for a `STOP` from a number of the United States, PC-61) and `all_marketing` otherwise, and its reference is the provider's message identifier, so a repeated webhook changes nothing;
    * `START` and `UNSTOP` record a new evidenced consent in Relay's own copy (writer `relay`, source `sms_keyword`); a revocation of another source, such as the registry's, stays in force;
    * `HELP` and `YARDIM` change nothing.

  It then returns the one reply of the message, a fixed text without marketing content (`Relay.Compliance.sms_reply/3`), or `nil` when the provider answered the keyword itself (`replied?`) or no sender identity can answer. `reply/2` sends it through the account that received the message, from the number it was addressed to, with the provider idempotency key `kw-<receipt id>`; it is called once, after the receipt is `processed`, and a reply that fails is not sent again. A number is answered at most `sms_keyword.reply_rate.limit` times in its window (`x-relay-limits`), counted under a keyed digest of the number, so that two machines never answer each other without end; past the limit, or when the counter cannot be read, the keyword still takes effect and only the reply is withheld. On the `test` plane nothing leaves Relay.

  `provider_opt_out/3` keeps Relay in step with a provider's own opt-out list (PC-37): a delivery report whose provider code says the recipient opted out at the provider (`opt_out_code?/2`) is the same refusal notice for the brand of that delivery, announced as `sms.opted_out`, and is never answered.
  """

  alias Relay.Channels.Live.Store
  alias Relay.Scope

  require Logger

  @call_ms 10_000
  @ttl_s 3_600
  @table "compliance_table"
  @types ~w(individual merchant)
  @reply_limit Relay.Limits.fetch!(["sms_keyword", "reply_rate", "limit"])
  @reply_window_ms Relay.Limits.seconds!(["sms_keyword", "reply_rate", "window"]) * 1000
  @opt_out %{
    "twilio" => ["21610"],
    "verimor" => ["dlr:BLACKLISTED_DESTINATION_ADDRESS"],
    "infobip" => ["status:REJECTED_DESTINATION_BLOCKLISTED"]
  }

  @type reply :: %{
          receipt_id: Relay.Id.t(),
          account_id: Relay.Id.t(),
          sender: map(),
          to: Relay.Redacted.t(),
          text: String.t(),
          key: String.t()
        }

  # PC-37
  # PC-39
  # PC-61
  # INV-18
  @doc "Applies the keyword of one received message, the opened item of the receipt `row`, and returns its reply or `nil`; see the module documentation. An error is a failure that may pass, and the receipt is tried again."
  @spec apply_message(Scope.t(), map(), map()) :: {:ok, reply() | nil} | {:error, term()}
  def apply_message(%Scope{} = scope, %{} = row, %{} = item) do
    case Relay.Compliance.sms_keyword(item["text"]) do
      :none -> {:ok, nil}
      {set, keyword} -> keyword(scope, row, item, {set, keyword})
    end
  end

  defp keyword(scope, row, %{"from" => "+" <> _digits = from} = item, {set, keyword}) do
    with {:ok, [{_key_id, digest} | _] = digests} <-
           Relay.Subscribers.address_digests(scope, "sms", from),
         {:ok, [_ | _] = recipients} <- recipients(scope, digests),
         {:ok, sender} <- Relay.Channels.sms_sender(scope, row["provider_account_id"], item["to"]),
         {:ok, revocation} <- revocation(set, from) do
      ctx = %{
        scope: scope,
        row: row,
        item: item,
        sender: sender,
        keyword: keyword,
        revocation: revocation,
        key: Base.url_encode64(digest, padding: false),
        at: occurred_at(item)
      }

      with :ok <- each(recipients, &act(ctx, set, &1)),
           do: {:ok, answer(ctx, set, from, hd(recipients))}
    else
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp keyword(_scope, _row, _item, _keyword), do: {:ok, nil}

  defp recipients(scope, digests) do
    bidxs = Enum.map(digests, &elem(&1, 1))
    Store.in_scope(scope, fn _status -> Store.sms_recipients(bidxs) end)
  end

  # PC-39
  # PC-61
  defp revocation(:stop, from) do
    with {:ok, table} <- table() do
      code = Relay.Phone.calling_code(from)

      scopes =
        for country <- Relay.Compliance.candidates(table, code, nil),
            do: Relay.Compliance.revocation_scope(table, country, "sms")

      {:ok, Relay.Compliance.sms_revocation(:stop, scopes)}
    end
  end

  defp revocation(set, _from), do: {:ok, Relay.Compliance.sms_revocation(set, [])}

  defp table do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), @table) do
      {:ok, %{content: %{"country_rows" => _rows} = content}} -> {:ok, content}
      {:ok, _none} -> {:ok, elem(Relay.Compliance.bundled_table(), 1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp each(recipients, fun) do
    Enum.reduce_while(recipients, :ok, fn recipient, :ok ->
      case fun.(recipient) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # PC-37
  # PC-39
  # PC-61
  # INV-18
  defp act(ctx, set, recipient) when set in [:tr_refusal, :stop] do
    attrs = %{
      recipient_id: recipient["id"],
      channel: "sms",
      source: "sms_keyword",
      scope: ctx.revocation.scope,
      covers: ctx.revocation.channels -- ["sms"],
      brand_subtenant_id: brand(ctx.sender),
      ref: ref(ctx, recipient),
      occurred_at: ctx.at,
      provider_account_id: ctx.row["provider_account_id"],
      actor_ref: actor_ref(ctx)
    }

    case Relay.Compliance.refuse(ctx.scope, attrs) do
      {:ok, _applied} -> :ok
      {:error, %Relay.Error{code: :not_found}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-37
  defp act(ctx, :restart, recipient) do
    ref = ref(ctx, recipient)

    attrs = %{
      recipient_id: recipient["id"],
      brand_subtenant_id: brand(ctx.sender),
      channel: "sms",
      status: "active",
      consent_kind: "explicit_opt_in",
      recipient_type: recipient_type(recipient),
      source: "sms_keyword",
      sequence: DateTime.to_unix(ctx.at, :millisecond),
      occurred_at: ctx.at,
      text_version_digest: :crypto.hash(:sha256, "sms_keyword:" <> ctx.keyword),
      evidence: %{
        "source" => "sms_keyword",
        "keyword" => ctx.keyword,
        "at" => DateTime.to_iso8601(ctx.at),
        "ref" => ref
      },
      iys_transaction_ref: nil,
      source_event_ref: ref,
      writer: "relay"
    }

    case Relay.Preferences.record_consent(ctx.scope, attrs) do
      {:ok, code} when code in [:recorded, :duplicate, :stale, :recipient_not_found] -> :ok
      {:ok, code} -> {:error, code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp act(_ctx, :help, _recipient), do: :ok

  defp recipient_type(%{"legal_type" => type}) when type in @types, do: type
  defp recipient_type(_recipient), do: "individual"

  defp brand(%{"subtenant_id" => <<_::128>> = id}), do: id
  defp brand(_none), do: nil

  defp ref(ctx, recipient) do
    id = Relay.Id.to_string(recipient["id"])
    message = String.slice(to_string(ctx.item["provider_message_id"]), 0, 128)
    "sms_keyword:" <> ctx.row["provider"] <> ":" <> message <> ":" <> id
  end

  defp actor_ref(ctx), do: "provider:" <> ctx.row["provider"]

  defp occurred_at(%{"received_at" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> Relay.Clock.utc_now()
    end
  end

  defp occurred_at(_item), do: Relay.Clock.utc_now()

  # PC-37
  defp answer(%{item: %{"replied" => true}}, _set, _from, _recipient), do: nil
  defp answer(%{sender: nil}, _set, _from, _recipient), do: nil
  defp answer(%{row: %{"provider_account_id" => nil}}, _set, _from, _recipient), do: nil

  defp answer(ctx, set, from, recipient) do
    locale = recipient["locale"] || locale(set, ctx.keyword, from)

    %{
      receipt_id: ctx.row["id"],
      account_id: ctx.row["provider_account_id"],
      sender: ctx.sender,
      to: Relay.Redacted.wrap(from),
      text: Relay.Compliance.sms_reply(kind(set), locale, header(ctx.sender)),
      key: ctx.key
    }
  end

  defp kind(:help), do: :help
  defp kind(:restart), do: :restarted
  defp kind(_refusal), do: :refused

  defp locale(:tr_refusal, _keyword, _from), do: "tr"
  defp locale(_set, "YARDIM", _from), do: "tr"
  defp locale(_set, _keyword, "+90" <> _rest), do: "tr"
  defp locale(_set, _keyword, _from), do: "en"

  defp header(%{"sms_type" => "alphanumeric", "value" => value}) when is_binary(value), do: value
  defp header(_sender), do: nil

  # PC-37
  # TN-26
  @doc "Sends the one reply of a received message through the account that received it; see the module documentation. A reply that is not accepted is logged and never sent again."
  @spec reply(Scope.t(), reply()) :: :ok
  def reply(%Scope{environment: :test}, _reply), do: :ok

  def reply(%Scope{} = scope, %{} = reply) do
    with :ok <- within_rate(scope, reply.key),
         {:ok, %{"state" => "active"} = account} <-
           Relay.Channels.provider_account(scope, reply.account_id),
         {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, adapter} <- Relay.Channels.activated_adapter(declarations, account["provider"]),
         {:accepted, _info} <- adapter.deliver(request(scope, account, reply)) do
      :ok
    else
      :withheld ->
        :ok

      _not_sent ->
        Logger.warning("a keyword reply was not sent",
          receipt_id: Relay.Id.to_string(reply.receipt_id)
        )

        :ok
    end
  end

  # PC-37
  # T-27
  defp within_rate(scope, key) do
    name = "sms_keyword_reply:" <> key

    case Relay.Platform.rate_counter(scope, name, @reply_window_ms, :incr, 1) do
      {:ok, count} when count <= @reply_limit -> :ok
      _over_or_unreadable -> :withheld
    end
  end

  # PC-37
  @doc "Whether a provider code of a delivery report says the recipient opted out at the provider."
  @spec opt_out_code?(String.t(), String.t() | nil) :: boolean()
  def opt_out_code?(provider, code), do: code in Map.get(@opt_out, provider, [])

  # PC-37
  # PC-38
  # INV-18
  @doc "Applies the provider's own opt-out that a recorded delivery report of an SMS shows: a refusal notice of the source `sms_keyword` for the delivery's recipient and brand, through the account the report came from; nothing is answered. An unknown delivery or recipient changes nothing."
  @spec provider_opt_out(Scope.t(), Relay.Id.t() | nil, map()) :: :ok
  def provider_opt_out(%Scope{} = scope, account_id, %{delivery_id: delivery_id} = event) do
    case Store.in_scope(scope, fn _status -> Store.delivery(delivery_id) end) do
      {:ok, %{"recipient_id" => <<_::128>> = recipient_id, "channel" => "sms"} = delivery} ->
        _applied =
          Relay.Compliance.refuse(scope, %{
            recipient_id: recipient_id,
            channel: "sms",
            source: "sms_keyword",
            brand_subtenant_id: delivery["subtenant_id"],
            ref: "provider_opt_out:" <> Relay.Id.to_string(delivery_id),
            occurred_at: Map.get(event, :occurred_at),
            provider_account_id: account_id,
            actor_ref: "provider:" <> event.provider
          })

        :ok

      _unknown ->
        :ok
    end
  end

  defp request(scope, account, reply) do
    Relay.Channels.request(%{
      scope: scope,
      delivery_id: reply.receipt_id,
      attempt_no: 1,
      channel: "sms",
      provider: account["provider"],
      idempotency_key: "kw-" <> Relay.Id.to_string(reply.receipt_id),
      target: %{kind: :address, id: nil, value: reply.to},
      timeout_ms: @call_ms,
      content: %{"body" => reply.text},
      credentials: credentials(scope, account),
      account: account,
      sender: reply.sender,
      ttl_s: @ttl_s,
      message_class: "transactional",
      encoding: "GSM7",
      commercial: %{commercial: false, iys_recipient_type: nil}
    })
  end

  defp credentials(_scope, %{"credential_ref_id" => nil}), do: nil

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> secret
      {:error, _error} -> nil
    end
  end
end
