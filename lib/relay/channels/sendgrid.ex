defmodule Relay.Channels.Sendgrid do
  @moduledoc """
  The SendGrid adapter (CH-3, CH-34): a thin client of SendGrid's v3 Mail Send API on `Req`, with no SDK. A message is the one `Relay.Channels.Email` prepares, sent as its fields to `POST /v3/mail/send` with the API key of the account's credential (`{"api_key"}`); SendGrid signs it with the domain's DKIM key and uses its own return path. Click, open and subscription tracking are always off, so a link reaches the recipient as written (CH-43, CH-76). The IP pool is the e-mail stream's `ip_pool`; `settings.sendgrid.region` `"eu"` sends to SendGrid's EU host.

  The delivery identifier travels as the custom argument `relay_delivery_id`, which every event carries. SendGrid has no idempotency key and no status query a send can be resolved by, so an uncertain call is not retried (CH-10). An accepted message's identifier is the `X-Message-Id` header; HTTP statuses are reported as `http_<status>`.

  Events come from SendGrid's Event Webhook, signed with ECDSA P-256 over the timestamp and the raw body (`Relay.Channels.verify_ecdsa/4`). `events/1` parses a webhook body, a JSON array, into `Relay.Channels.Email.Event`s.

  The settings check lists the authenticated domains (`GET /v3/whitelabel/domains`): every sending domain of the account's streams, or a parent domain of it, must be authenticated and valid, or SendGrid sends unaligned mail (CH-14, CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @hosts %{"global" => "https://api.sendgrid.com", "eu" => "https://api.eu.sendgrid.com"}
  @types %{
    "delivered" => :delivered,
    "bounce" => :bounced,
    "blocked" => :bounced,
    "dropped" => :rejected,
    "deferred" => :deferred,
    "spamreport" => :complained,
    "open" => :engagement,
    "click" => :engagement,
    "unsubscribe" => :engagement,
    "group_unsubscribe" => :engagement,
    "group_resubscribe" => :engagement
  }

  @impl Relay.Channels.Adapter
  def provider, do: "sendgrid"

  @impl Relay.Channels.Adapter
  def channels, do: ["email"]

  # CH-3
  # CH-34
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, key} <- key(request),
         {:ok, prepared} <- Esp.prepare(request) do
      settings = Esp.settings(request, "sendgrid")
      host = Map.get(@hosts, Map.get(settings, "region", "global"), @hosts["global"])

      opts = [
        method: :post,
        url: host <> "/v3/mail/send",
        headers: [
          {"authorization", "Bearer " <> key},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(message(request, prepared))
      ]

      case Esp.call(request, opts) do
        {:ok, %Req.Response{status: 202} = response} -> accepted(response)
        {:ok, %Req.Response{} = response} -> Esp.status_rejected(response)
        other -> other
      end
    end
  end

  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    with {:ok, map} <- Esp.credential_map(credentials),
         {:ok, key} <- Esp.secret(map, "api_key") do
      region = Map.get(Esp.account_settings(account, "sendgrid"), "region", "global")
      host = Map.get(@hosts, region, @hosts["global"])

      opts = [
        method: :get,
        url: host <> "/v3/whitelabel/domains",
        headers: [{"authorization", "Bearer " <> key}, {"accept", "application/json"}],
        params: [limit: 200]
      ]

      timeout_ms
      |> Esp.http(opts)
      |> SettingsCheck.read(&domains(&1, SettingsCheck.stream_domains(account)))
    else
      :error -> SettingsCheck.credentials(nil)
    end
  end

  defp domains(%Req.Response{status: 200, body: body}, wanted) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        valid = for %{"domain" => domain, "valid" => true} <- list, do: domain
        missing(wanted, valid)

      _other ->
        {:error, "unexpected_response"}
    end
  end

  defp domains(%Req.Response{status: status}, _wanted), do: {:error, Esp.http_code(status)}

  defp missing(wanted, valid) do
    case Enum.find(wanted, fn domain -> not authenticated?(domain, valid) end) do
      nil -> :ok
      domain -> SettingsCheck.mismatch("domain_authentication", "valid", domain)
    end
  end

  defp authenticated?(domain, valid),
    do: Enum.any?(valid, &(domain == &1 or String.ends_with?(domain, "." <> &1)))

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status}) when is_integer(status),
    do: %{code: Esp.http_code(status), status: status}

  def decode(%{"failure" => failure}) when is_binary(failure), do: %{code: failure, status: nil}

  def decode(%{"event" => event}) do
    [%Event{code: code} | _rest] = events([event])
    %{code: "event:" <> code, status: nil}
  end

  defp key(request) do
    with {:ok, credentials} <- Esp.credentials(request),
         {:ok, key} <- Esp.secret(credentials, "api_key") do
      {:ok, key}
    else
      :error -> Esp.refused("credential_invalid")
    end
  end

  defp message(request, prepared) do
    content =
      [{"text/plain", prepared.text}, {"text/html", prepared.html}]
      |> Enum.reject(fn {_type, value} -> is_nil(value) end)
      |> Enum.map(fn {type, value} -> %{"type" => type, "value" => value} end)

    %{
      "personalizations" => [
        %{
          "to" => [%{"email" => prepared.to}],
          "custom_args" => %{
            Event.correlation_key() => Relay.Id.to_string(request.delivery_id)
          }
        }
      ],
      "from" => address(prepared.from, prepared.from_name),
      "subject" => prepared.subject,
      "content" => content,
      "headers" => Map.new([{"Message-ID", prepared.message_id} | prepared.headers]),
      "tracking_settings" => %{
        "click_tracking" => %{"enable" => false, "enable_text" => false},
        "open_tracking" => %{"enable" => false},
        "subscription_tracking" => %{"enable" => false},
        "ganalytics" => %{"enable" => false}
      }
    }
    |> put("reply_to", prepared.reply_to && address(prepared.reply_to, nil))
    |> put("ip_pool_name", prepared.ip_pool)
  end

  defp address(email, nil), do: %{"email" => email}
  defp address(email, name), do: %{"email" => email, "name" => name}

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp accepted(response) do
    id =
      case Req.Response.get_header(response, "x-message-id") do
        [id | _rest] -> id
        [] -> nil
      end

    {:accepted, %{provider_message_id: id, delivery_rank: :accepted}}
  end

  # CH-39
  # CH-47
  @doc "Parses a SendGrid Event Webhook body (a JSON array, decoded or as text) into its events; an event type Relay does not act on is `:ignored`."
  @spec events(binary() | list()) :: [Event.t()]
  def events(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> events(list)
      _other -> []
    end
  end

  def events(list) when is_list(list), do: for(%{} = item <- list, do: event(item))

  defp event(item) do
    name = text(item["event"]) || "unknown"
    type = Map.get(@types, name, :ignored)
    code = if name == "bounce", do: "bounce:" <> (text(item["type"]) || "bounce"), else: name

    %Event{
      provider: "sendgrid",
      type: type,
      code: code,
      id: text(item["sg_event_id"]),
      delivery_id:
        Event.first_delivery_id([text(item[Event.correlation_key()]), text(item["smtp-id"])]),
      provider_message_id: message_id(item["sg_message_id"]),
      recipient: Event.redact(item["email"]),
      occurred_at: Event.timestamp(item["timestamp"]),
      status: text(item["status"]),
      diagnostic: Event.redact(item["reason"] || item["response"])
    }
  end

  defp message_id(id) when is_binary(id), do: id |> String.split(".") |> hd()
  defp message_id(_id), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
