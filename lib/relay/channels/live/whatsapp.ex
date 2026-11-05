defmodule Relay.Channels.Live.Whatsapp do
  @moduledoc """
  WhatsApp on the running send path and its inbound webhooks (CH-57 … CH-61, PC-43).

  Before a WhatsApp attempt the channel step calls `prepare/4`:

    * A number that is unusable for a while (a throughput upgrade, `131057`) holds the delivery with `whatsapp.number_unavailable` until it is usable again (CH-61).
    * The customer service window of the recipient on the number decides the kind: free-form text only while it is open, the template otherwise; content that offers only free-form text into a closed window is skipped with `whatsapp.window_closed` (CH-58). A window that cannot be read is closed.
    * A template is sent only when it is registered for the provider account and approved; otherwise the delivery is skipped with `whatsapp.template_not_approved` (CH-57, TP-23, CH-14).
    * A template outside the window reaches a recipient that counts toward the portfolio's messaging limit tier: the recipient is added to the 24-hour membership set once, and the tenant is warned with `whatsapp_tier.threshold_reached` when the count reaches the warning share (CH-61). An unreadable count never blocks the send; Meta enforces the tier.

  `inbound/5` takes a verified webhook of a provider account (`X-Hub-Signature-256` over the raw body, CH-60) and applies each item:

    * a message status is recorded once by its `wamid + status + timestamp` key as an inbound receipt and appended to the delivery's ledger with its whole `pricing` object; duplicates and out-of-order statuses are expected and the ledger moves only forward (`status_event/2` is the one place a status becomes a provider event, recorded through `Relay.Channels.Live.Events.record/2`). A failed status with `131050` writes the recipient's marketing opt-out (PC-43), and `131026` soft disables the address (CH-11);
    * an inbound message opens the recipient's window again;
    * a template status, category or edit updates the template (CH-57, TP-23);
    * `account_update` is announced as `whatsapp_account.updated` with its `violation_type`;
    * a marketing `stop` in `user_preferences` is written to the preference register as an opt-out of every marketing category on WhatsApp, with no consent requirement added (PC-43); a `resume` is never turned into consent;
    * a messaging limit change records the portfolio's tier, and a throughput upgrade marks the number unusable and is announced as `whatsapp_number.paused` (CH-61).

  Valkey holds the window, tier and availability values only as short-lived signals: a lost window is closed, a lost tier is the default tier and a lost availability is available.
  """

  alias Relay.Channels.Live.Events
  alias Relay.Channels.Live.Store

  require Logger

  @provider "whatsapp_cloud"
  @channel "whatsapp"
  @limits "whatsapp_messaging_limits"
  @day_ms 24 * 60 * 60 * 1000

  @type prepared :: {:ok, map()} | {:skip, String.t()} | {:hold, String.t(), pos_integer()}

  # CH-57
  # CH-58
  # CH-61
  @doc "Prepares the content of a WhatsApp attempt on `account` for the recipient `to` (E.164): the number's availability, the window, the template's approval and the tier count; returns the content with its chosen `kind`, a skip or a hold with its rule."
  @spec prepare(Relay.Scope.t(), map(), String.t(), map()) :: prepared()
  def prepare(%Relay.Scope{} = scope, account, to, content) when is_map(content) do
    number = get_in(account, ["settings", "phone_number_id"])
    member = member(scope, to)

    with :ok <- available(scope, number),
         {:ok, content, kind} <- choose(scope, number, member, content),
         :ok <- template(scope, account, content, kind) do
      if kind == :template, do: count(scope, account, member)
      {:ok, content}
    end
  end

  defp available(_scope, nil), do: :ok

  defp available(scope, number) do
    case Relay.Platform.get_short_lived(scope, ["wa_unavailable", number]) do
      {:ok, until} when is_binary(until) ->
        wait_ms = String.to_integer(until) - now_ms()

        if wait_ms > 0,
          do: {:hold, "whatsapp.number_unavailable", max(div(wait_ms, 1000), 1)},
          else: :ok

      _missing_or_unreadable ->
        :ok
    end
  end

  defp choose(scope, number, member, content) do
    case Relay.Channels.whatsapp_choose(window_open?(scope, number, member), content) do
      {:ok, content, kind} -> {:ok, content, kind}
      {:error, _closed_or_empty} -> {:skip, "whatsapp.window_closed"}
    end
  end

  defp template(_scope, _account, _content, :free_form), do: :ok

  defp template(scope, account, content, :template) do
    case Relay.Channels.whatsapp_template_sendable(scope, account["id"], content) do
      :ok -> :ok
      {:error, _state} -> {:skip, "whatsapp.template_not_approved"}
    end
  end

  # CH-58
  @doc "Whether the window of a recipient (its address digest member) is open on a number now; an unreadable window is closed."
  @spec window_open?(Relay.Scope.t(), String.t() | nil, String.t() | nil) :: boolean()
  def window_open?(_scope, nil, _member), do: false
  def window_open?(_scope, _number, nil), do: false

  def window_open?(scope, number, member) do
    case Relay.Platform.get_short_lived(scope, ["wa_csw", number, member]) do
      {:ok, value} when is_binary(value) ->
        last = DateTime.from_unix!(String.to_integer(value), :millisecond)
        Relay.Channels.whatsapp_window_open?(last, Relay.Clock.utc_now())

      _missing_or_unreadable ->
        false
    end
  end

  # CH-58
  @doc "Opens the window of a recipient on a number again from an inbound message at `at`; a later message already recorded is kept."
  @spec refresh_window(Relay.Scope.t(), String.t(), String.t(), DateTime.t()) :: :ok
  def refresh_window(scope, number, member, %DateTime{} = at) do
    path = ["wa_csw", number, member]
    at_ms = DateTime.to_unix(at, :millisecond)

    last_ms =
      case Relay.Platform.get_short_lived(scope, path) do
        {:ok, value} when is_binary(value) -> String.to_integer(value)
        _missing -> 0
      end

    latest = max(at_ms, last_ms)
    ttl_ms = latest + Relay.Channels.whatsapp_window_ms() - now_ms()

    if ttl_ms > 0, do: put(scope, path, Integer.to_string(latest), ttl_ms)
    :ok
  end

  # CH-61
  defp count(scope, account, member) when is_binary(member) do
    limits = limits()
    portfolio = portfolio(account)
    path = ["wa_tier", portfolio]
    window = Map.get(limits, "window_ms", @day_ms)
    limit = Relay.Channels.whatsapp_tier_limit(limits, tier(scope, portfolio))

    with {:ok, %{count: others}} <- sliding_count(scope, path, window, member),
         {:ok, %{count: before}} <- sliding_count(scope, path, window, "-"),
         true <- before == others,
         {:ok, after_count} <- Relay.Platform.sliding_set_add(scope, path, window, member) do
      if Relay.Channels.whatsapp_tier_warn?(limits, before, after_count, limit) do
        data = %{
          "portfolio" => portfolio,
          "count" => after_count,
          "limit" => limit,
          "warn_percent" => div(limits["warn_bp"], 100)
        }

        type = "whatsapp_tier.threshold_reached"
        _ = Relay.Channels.whatsapp_event(scope, type, stream(portfolio), data)
      end

      :ok
    else
      false -> :ok
      {:error, reason} -> unreadable(:tier, reason)
    end
  end

  defp count(_scope, _account, nil), do: :ok

  defp sliding_count(scope, path, window, member),
    do: Relay.Platform.sliding_set_count(scope, path, window, member, 1)

  defp tier(scope, portfolio) do
    case Relay.Platform.get_short_lived(scope, ["wa_tier_limit", portfolio]) do
      {:ok, value} when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp portfolio(account) do
    settings = Map.get(account, "settings") || %{}
    segment(settings["business_id"]) || segment(settings["waba_id"]) || "account"
  end

  defp segment(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]{1,32}\z/, value), do: value
  end

  defp segment(_value), do: nil

  defp limits do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), @limits) do
      {:ok, %{content: %{} = content}} -> content
      _none -> Relay.Channels.whatsapp_bundled(@limits)
    end
  end

  # CH-60
  # CH-3
  # T-40
  @doc "Verifies and applies an inbound webhook of a WhatsApp provider account: `app_secret` is the Meta app secret the signature is checked with, `body` the raw request body and `headers` its lower-case headers. Returns the number of applied items; a bad signature is an error and nothing is applied."
  @spec inbound(
          Relay.Scope.t(),
          map(),
          Relay.Redacted.t(),
          binary(),
          [{String.t(), String.t()}]
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def inbound(%Relay.Scope{} = scope, account, app_secret, body, headers) when is_binary(body) do
    with {:ok, items} <- Relay.Channels.whatsapp_webhook(app_secret, body, headers) do
      ctx = %{scope: scope, account: account, digest: digest(body)}
      {:ok, Enum.count(items, &(apply_item(ctx, &1) == :applied))}
    end
  end

  defp digest(body), do: :crypto.hash(:sha256, body)

  defp apply_item(ctx, {:status, _number, event}), do: status(ctx, event)

  defp apply_item(ctx, {:inbound, message}) do
    with number when is_binary(number) <- message.phone_number_id,
         member when is_binary(member) <- member(ctx.scope, "+" <> message.wa_id) do
      refresh_window(ctx.scope, number, member, message.at)
      :applied
    else
      _unknown -> :ignored
    end
  end

  defp apply_item(ctx, {kind, _change} = item)
       when kind in [:template_status, :template_category, :template_edit] do
    key = "template:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(item)))

    with {:ok, {:recorded, receipt_id}} <- receipt(ctx, key),
         _ = Relay.Webhooks.mark_receipt(ctx.scope, receipt_id, :processed, nil),
         {:ok, result} when result in [:changed, :recorded, :drifted, :aligned] <-
           Relay.Channels.whatsapp_template_change(ctx.scope, ctx.account["id"], item) do
      :applied
    else
      _duplicate_or_unknown -> :ignored
    end
  end

  defp apply_item(ctx, {:account_update, change}) do
    data = %{
      "provider_account_id" => Relay.Id.to_string(ctx.account["id"]),
      "waba_id" => change.waba_id,
      "event" => change.event,
      "violation_type" => change.violation_type
    }

    stream = stream(change.waba_id || "account")
    applied(Relay.Channels.whatsapp_event(ctx.scope, "whatsapp_account.updated", stream, data))
  end

  defp apply_item(ctx, {:user_preference, %{value: :stop} = preference}),
    do: opt_out(ctx.scope, "+" <> preference.wa_id, "whatsapp:user_preferences")

  defp apply_item(ctx, {:messaging_limit, change}) do
    portfolio = portfolio(ctx.account)

    if is_binary(change.limit),
      do: put(ctx.scope, ["wa_tier_limit", portfolio], change.limit, 30 * @day_ms)

    if change.event == "THROUGHPUT_UPGRADE",
      do: unavailable(ctx.scope, ctx.account, "throughput_upgrade")

    :applied
  end

  defp apply_item(_ctx, _item), do: :ignored

  # CH-61
  @doc "Marks a provider account's number unusable for the data set's upgrade time and announces `whatsapp_number.paused` with its reason."
  @spec unavailable(Relay.Scope.t(), map(), String.t()) :: :ok
  def unavailable(scope, account, reason) do
    case get_in(account, ["settings", "phone_number_id"]) do
      number when is_binary(number) ->
        ms = Map.get(limits(), "upgrade_unavailable_ms", 60_000)
        until = now_ms() + ms
        put(scope, ["wa_unavailable", number], Integer.to_string(until), ms)

        data = %{
          "phone_number_id" => number,
          "reason" => reason,
          "until" => until |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
        }

        type = "whatsapp_number.paused"
        _ = Relay.Channels.whatsapp_event(scope, type, stream(number), data)
        :ok

      _none ->
        :ok
    end
  end

  # CH-60
  # DS-12
  defp status(ctx, event) do
    with {delivery_id, _attempt_no} <- event.correlation,
         {:ok, %{} = delivery} <- read_delivery(ctx.scope, delivery_id),
         {:ok, {:recorded, receipt_id}} <- receipt(ctx, event.dedup_key),
         {:ok, _recorded} <- Events.record(ctx.scope, status_event(event, receipt_id)) do
      failed(ctx, delivery, event)
      :applied
    else
      _unknown_or_duplicate -> :ignored
    end
  end

  defp read_delivery(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.delivery(delivery_id) end)

  defp receipt(ctx, key) do
    Relay.Webhooks.record_receipt(ctx.scope, %{
      id: Relay.Id.generate(),
      provider: @provider,
      provider_account_id: ctx.account["id"],
      provider_event_id: key,
      body_digest: ctx.digest
    })
  end

  # CH-60
  # DS-12
  @doc "The provider event of a normalized WhatsApp status (`Relay.Channels.Whatsapp.Status.normalize/1`) for `Relay.Channels.Live.Events.record/2`: its event code is the status, a failure carries the code of its first error, and the whole `pricing` object is the event's price."
  @spec status_event(map(), Relay.Id.t() | nil) :: Events.event()
  def status_event(event, receipt_id) do
    {delivery_id, _attempt_no} = event.correlation

    %{
      delivery_id: delivery_id,
      provider: @provider,
      channel: @channel,
      event_code: event.event_code,
      occurred_at: event.occurred_at,
      actor: :provider_webhook,
      raw_code: event.raw_code,
      receipt_id: receipt_id,
      price: event.pricing,
      detail: detail(event)
    }
  end

  defp detail(event) do
    %{
      "wamid" => event.provider_message_id,
      "conversation" => event.conversation,
      "errors" => Enum.map(event.errors, &Map.take(&1, ["code", "title"]))
    }
  end

  # CH-11
  # CH-59
  # PC-43
  defp failed(ctx, delivery, %{event_code: "failed", raw_code: code}) do
    recipient_id = delivery["recipient_id"]

    case Relay.Channels.whatsapp_follow_up(code) do
      :never_retry when code == "131050" ->
        opt_out_recipient(ctx.scope, recipient_id, "whatsapp:131050")

      :never_retry ->
        rule_id = "channel.address_disabled"
        Relay.Channels.disable_address(ctx.scope, recipient_id, "phone", @channel, rule_id)

      :number_unavailable ->
        unavailable(ctx.scope, ctx.account, "maintenance")

      _other ->
        :ok
    end

    :ok
  end

  defp failed(_ctx, _delivery, _event), do: :ok

  # PC-43
  defp opt_out(scope, phone, actor_ref) do
    with {:ok, [_ | _] = digests} <- Relay.Subscribers.address_digests(scope, @channel, phone),
         {:ok, [_ | _] = recipients} <- recipients(scope, Enum.map(digests, &elem(&1, 1))) do
      Enum.each(recipients, &opt_out_recipient(scope, &1, actor_ref))
      :applied
    else
      _unknown -> :ignored
    end
  end

  defp recipients(scope, digests) do
    Store.in_scope(scope, fn _status ->
      %Postgrex.Result{rows: rows} =
        Relay.Repo.scoped_query!(
          """
          SELECT DISTINCT a.recipient_id FROM relay.recipient_addresses a
          WHERE a.kind = 'phone' AND a.state = 'active'
            AND (a.address_bidx = ANY ($1) OR a.address_bidx_next = ANY ($1))
          """,
          [digests]
        )

      Enum.map(rows, &hd/1)
    end)
  end

  # PC-43
  # CH-59
  @doc "Writes a recipient's WhatsApp marketing opt-out to the preference register: an opt-out of every active marketing category on WhatsApp, written as `unsubscribe`, so it can only turn sending off."
  @spec opt_out_recipient(Relay.Scope.t(), Relay.Id.t(), String.t()) :: :ok
  def opt_out_recipient(scope, recipient_id, actor_ref) do
    result =
      Relay.Preferences.in_scope(scope, fn _status ->
        writes =
          for category <- marketing_categories(),
              do: %{level: "category_channel", key: category, channel: @channel, value: "opt_out"}

        Relay.Preferences.write_preferences(recipient_id, writes, "unsubscribe", actor_ref)
      end)

    case result do
      {:ok, :ok} -> :ok
      other -> unreadable(:preference, other)
    end
  end

  defp marketing_categories do
    %Postgrex.Result{rows: rows} =
      Relay.Repo.scoped_query!(
        """
        SELECT c.key FROM relay.categories c
        WHERE c.message_class = 'marketing' AND c.state = 'active'
        ORDER BY c.key
        """,
        []
      )

    Enum.map(rows, &hd/1)
  end

  defp member(scope, phone) when is_binary(phone) do
    case Relay.Subscribers.address_digests(scope, @channel, phone) do
      {:ok, [{_key_id, digest} | _]} -> Base.url_encode64(digest, padding: false)
      _unreadable -> nil
    end
  end

  defp member(_scope, _phone), do: nil

  defp put(scope, path, value, ttl_ms) do
    case Relay.Platform.put_short_lived(scope, path, value, ttl_ms) do
      :ok -> :ok
      {:error, reason} -> unreadable(:valkey, reason)
    end
  end

  defp stream(ref), do: "whatsapp:" <> ref

  defp now_ms, do: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

  defp applied({:ok, _value}), do: :applied
  defp applied(_error), do: :ignored

  defp unreadable(what, reason) do
    Logger.warning("a WhatsApp signal could not be read or written",
      what: what,
      reason: inspect(reason)
    )

    :ok
  end
end
