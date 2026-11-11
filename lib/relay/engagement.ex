defmodule Relay.Engagement do
  @moduledoc """
  The e-mail engagement Relay observes on its own tracking endpoints (CH-43, DS-29…DS-34, DS-52): a click on a wrapped link and a fetch of the open pixel. Both are recorded in the delivery's append-only ledger whatever the delivery's outcome, so the engagement axis moves independently of delivery (DS-33):

    * A click is classified `human` or `likely_bot` with the active `click_signals` data set (`Relay.Channels.classify_click/4`); the class, the deciding signal, the link number and the data set version are kept on the `engagement.clicked` entry. A human click is the recipient's own action (`actor = user`), a `reliable` engagement signal and e-mail delivery evidence: it raises the delivery to `delivered` when no provider evidence did (DS-31, DS-34). A likely bot click is recorded by Relay (`actor = relay`), is `unreliable` and changes nothing else.
    * An open is the `engagement.opened` entry with its `machine_open` flag (DS-32); it is never delivery evidence and never decision input, so it is always `unreliable`.

  A push has no tracking endpoint: the mobile or web SDK posts its displayed and clicked receipts (`record_receipt/4`, DS-13), the only delivery evidence of a push.

  A click on a link Relay did not sign, or of another channel, records nothing; the redirect follows only a verified token. The URL is never kept in the ledger, only its link number.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Channels, Relay.Datasets, Relay.Delivery],
    exports: []

  @type request :: %{
          required(:method) => String.t(),
          required(:ip) => :inet.ip_address() | nil,
          required(:user_agent) => String.t() | nil,
          required(:headers) => [String.t()],
          required(:at_ms) => integer()
        }
  @default_window_ms 10_000
  @push ["push", "web_push"]

  # CH-43
  # CH-44
  # DS-30
  # DS-34
  @doc "Verifies a click token and records the click; returns the URL to redirect to, `:invalid` for a token that does not verify and `:unavailable` while the key store cannot verify it. A recording that fails does not stop the redirect."
  @spec click(String.t(), request()) :: {:ok, String.t()} | {:error, :invalid | :unavailable}
  def click(token, request) do
    case Relay.Channels.read_tracking_token(token, :click) do
      {:ok, decoded} ->
        _ = record_click(decoded, request)
        {:ok, decoded.url}

      {:error, :invalid} ->
        {:error, :invalid}

      {:error, %Relay.Error{}} ->
        {:error, :unavailable}
    end
  end

  # DS-32
  @doc "Verifies an open pixel token and records the open with its machine open flag; an invalid token records nothing."
  @spec open(String.t(), request()) :: :ok | {:error, :invalid | :unavailable}
  def open(token, request) do
    case Relay.Channels.read_tracking_token(token, :open) do
      {:ok, decoded} ->
        _ = record_open(decoded, request)
        :ok

      {:error, :invalid} ->
        {:error, :invalid}

      {:error, %Relay.Error{}} ->
        {:error, :unavailable}
    end
  end

  # DS-30
  # DS-31
  # DS-34
  @doc "Records a verified click of `decoded` (`scope`, `delivery_id`, `link`); returns the ledger result with the class and the deciding signal."
  @spec record_click(map(), request()) ::
          {:ok, {atom(), :human | :likely_bot, String.t() | nil}} | {:error, term()}
  def record_click(%{scope: scope, delivery_id: delivery_id, link: link}, request) do
    with {:ok, {signals, ref}} <- signals(),
         since = since(request.at_ms, signals),
         {:ok, %{"channel" => "email"} = delivery} <-
           Relay.Delivery.engagement(scope, delivery_id, since) do
      {class, signal} = Relay.Channels.classify_click(signals, request, link, history(delivery))
      entry = click_entry(delivery, request, link, {class, signal, ref})
      :telemetry.execute([:relay, :engagement, :click], %{count: 1}, %{class: class})

      with {:ok, result} <- append(scope, entry), do: {:ok, {result, class, signal}}
    else
      {:ok, _other} -> {:error, :not_trackable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp click_entry(delivery, request, link, {class, signal, ref}) do
    human? = class == :human

    %{
      delivery_id: delivery["id"],
      actor: if(human?, do: :user, else: :relay),
      event_type: "engagement.clicked",
      at_ms: request.at_ms,
      delivery_rank: if(human? and delivery["delivery_rank"] < 2, do: :delivered),
      detail: %{
        "engagement" => %{
          "kind" => "clicked",
          "source" => "tracked_link",
          "clicked_by" => Atom.to_string(class)
        },
        "link" => link,
        "class" => Atom.to_string(class),
        "signal" => signal,
        "decision_grade" => if(human?, do: "reliable", else: "unreliable"),
        "click_signals" => ref
      }
    }
  end

  # DS-32
  @doc "Records a verified open of `decoded` (`scope`, `delivery_id`); returns the ledger result with the machine open flag."
  @spec record_open(map(), request()) :: {:ok, {atom(), boolean()}} | {:error, term()}
  def record_open(%{scope: scope, delivery_id: delivery_id}, request) do
    with {:ok, {signals, ref}} <- signals(),
         since = DateTime.from_unix!(request.at_ms, :millisecond),
         {:ok, %{"channel" => "email"}} <- Relay.Delivery.engagement(scope, delivery_id, since) do
      {machine?, signal} = Relay.Channels.machine_open(signals, request)

      entry = %{
        delivery_id: delivery_id,
        actor: :relay,
        event_type: "engagement.opened",
        at_ms: request.at_ms,
        delivery_rank: nil,
        detail: %{
          "machine_open" => machine?,
          "signal" => signal,
          "decision_grade" => "unreliable",
          "click_signals" => ref
        }
      }

      :telemetry.execute([:relay, :engagement, :open], %{count: 1}, %{machine_open: machine?})

      with {:ok, result} <- append(scope, entry), do: {:ok, {result, machine?}}
    else
      {:ok, _other} -> {:error, :not_trackable}
      {:error, reason} -> {:error, reason}
    end
  end

  # DS-13
  # DS-8
  @doc "Records an SDK receipt (`:displayed` or `:clicked`) of a push delivery of `subscriber_id` at the device's `occurred_at`, inside the caller's scoped transaction: a displayed receipt is the push's delivery evidence and raises the delivery to `delivered`, a clicked one is engagement only; both are `reliable` and recorded with `actor = client_sdk`. A delivery of another subscriber or channel is `:delivery_not_found`."
  @spec record_receipt(Relay.Id.t(), Relay.Id.t(), :displayed | :clicked, DateTime.t()) ::
          {:ok, atom()} | {:error, :delivery_not_found}
  def record_receipt(subscriber_id, delivery_id, kind, %DateTime{} = occurred_at)
      when kind in [:displayed, :clicked] do
    case Relay.Delivery.engagement_in_scope(delivery_id, occurred_at) do
      %{"recipient_id" => ^subscriber_id, "channel" => channel} = delivery
      when channel in @push ->
        displayed? = kind == :displayed

        {:ok, entry} =
          Relay.Delivery.ledger_entry(
            id: Relay.Id.generate(),
            delivery_id: delivery_id,
            actor: :client_sdk,
            event_type: "engagement." <> Atom.to_string(kind),
            occurred_at: occurred_at,
            delivery_rank: if(displayed? and delivery["delivery_rank"] < 2, do: :delivered),
            detail: %{"engagement" => receipt_axis(kind), "decision_grade" => "reliable"}
          )

        {result, _rank, _version} = Relay.Delivery.append_ledger_in_scope(entry)
        {:ok, result}

      _other ->
        {:error, :delivery_not_found}
    end
  end

  defp receipt_axis(:displayed), do: %{"kind" => "seen", "source" => "client_sdk"}

  defp receipt_axis(:clicked),
    do: %{"kind" => "clicked", "source" => "client_sdk", "clicked_by" => "human"}

  defp signals do
    Relay.Datasets.decide(Relay.Datasets.installation_scope(), "click_signals", & &1)
  end

  defp since(at_ms, signals) do
    window =
      case get_in(signals, ["burst", "window_ms"]) do
        ms when is_integer(ms) -> ms
        _none -> @default_window_ms
      end

    DateTime.from_unix!(at_ms - window, :millisecond)
  end

  defp history(delivery) do
    %{
      sent_ms: ms(delivery["accepted_at"]),
      delivered_ms: ms(delivery["delivered_at"]),
      clicks: for({n, at} <- delivery["clicks"], do: {n, ms(at)})
    }
  end

  defp ms(nil), do: nil
  defp ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  defp append(scope, entry) do
    {:ok, ledger} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: entry.delivery_id,
        actor: entry.actor,
        event_type: entry.event_type,
        occurred_at: DateTime.from_unix!(entry.at_ms, :millisecond),
        delivery_rank: entry.delivery_rank,
        detail: entry.detail
      )

    case Relay.Delivery.append_ledger(scope, ledger) do
      {:ok, {result, _rank, _version}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
