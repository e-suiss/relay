defmodule Relay.Channels.Mailgun do
  @moduledoc """
  The Mailgun adapter (CH-3, CH-34): a thin client of Mailgun's messages API on `Req`, with no SDK. A message is the one `Relay.Channels.Email` prepares, sent as form fields to `POST /v3/<domain>/messages` with the API key of the account's credential (`{"api_key"}`) as basic authentication; the domain is the e-mail stream's sending domain, which Mailgun signs with its DKIM key. Tracking is always off (`o:tracking`, `o:tracking-clicks`, `o:tracking-opens`), so a link reaches the recipient as written (CH-43, CH-76). `settings.mailgun.region` `"eu"` sends to Mailgun's EU host.

  The delivery identifier travels as the user variable `relay_delivery_id`, which every event carries. Mailgun has no idempotency key and no status query a send can be resolved by, so an uncertain call is not retried (CH-10). HTTP statuses are reported as `http_<status>`.

  Events come from Mailgun's webhooks. Their signature is an HMAC-SHA256 of the timestamp and a token inside the JSON body, not of the body itself, so their authenticity is declared unverifiable (§12.1.2) and `verify/3` checks the signature, the timestamp and the token; `events/1` parses a webhook body into `Relay.Channels.Email.Event`s.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Request

  @hosts %{"global" => "https://api.mailgun.net", "eu" => "https://api.eu.mailgun.net"}
  @tolerance_s 300

  @impl Relay.Channels.Adapter
  def provider, do: "mailgun"

  @impl Relay.Channels.Adapter
  def channels, do: ["email"]

  # CH-3
  # CH-34
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, key} <- key(request),
         {:ok, prepared} <- Esp.prepare(request) do
      settings = Esp.settings(request, "mailgun")
      host = Map.get(@hosts, Map.get(settings, "region", "global"), @hosts["global"])

      opts = [
        method: :post,
        url: host <> "/v3/" <> URI.encode(prepared.domain) <> "/messages",
        auth: {:basic, "api:" <> key},
        form: form(request, prepared)
      ]

      case Esp.call(request, opts) do
        {:ok, %Req.Response{status: 200} = response} -> accepted(response)
        {:ok, %Req.Response{} = response} -> Esp.rejected(response, Esp.http_code(response.status))
        other -> other
      end
    end
  end

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status}) when is_integer(status),
    do: %{code: Esp.http_code(status), status: status}

  def decode(%{"failure" => failure}) when is_binary(failure), do: %{code: failure, status: nil}

  def decode(%{"event" => event}) do
    [%Event{code: code} | _rest] = events(%{"event-data" => event})
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

  defp form(request, prepared) do
    variables = %{Event.correlation_key() => Relay.Id.to_string(request.delivery_id)}

    headers =
      for {name, value} <- [{"Message-ID", prepared.message_id} | prepared.headers],
          do: {"h:" <> name, value}

    [
      {"from", from(prepared)},
      {"to", prepared.to},
      {"subject", prepared.subject},
      {"text", prepared.text},
      {"html", prepared.html},
      {"h:Reply-To", prepared.reply_to},
      {"o:tracking", "no"},
      {"o:tracking-clicks", "no"},
      {"o:tracking-opens", "no"},
      {"v:" <> Event.correlation_key(), variables[Event.correlation_key()]}
    ]
    |> Kernel.++(headers)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp from(%{from_name: nil, from: from}), do: from
  defp from(%{from_name: name, from: from}), do: ~s("#{String.replace(name, "\"", "")}" <#{from}>)

  defp accepted(response) do
    id =
      case Esp.json(response) do
        %{"id" => id} when is_binary(id) -> id
        _other -> nil
      end

    {:accepted, %{provider_message_id: id, delivery_rank: :accepted}}
  end

  # T-40
  # CH-47
  @doc "Checks the signature of a Mailgun webhook body against the webhook signing key: the HMAC-SHA256 of timestamp and token, compared in constant time, with a timestamp within 300 seconds of `now`."
  @spec verify(Relay.Redacted.t(), map(), DateTime.t()) ::
          :ok | {:error, :missing_signature | :bad_signature | :stale_timestamp}
  def verify(key, %{"signature" => %{} = signature}, %DateTime{} = now) do
    with timestamp when is_binary(timestamp) <- signature["timestamp"],
         token when is_binary(token) <- signature["token"],
         given when is_binary(given) <- signature["signature"],
         {seconds, ""} <- Integer.parse(timestamp),
         {:fresh, true} <- {:fresh, abs(DateTime.to_unix(now) - seconds) <= @tolerance_s} do
      expected =
        :hmac
        |> :crypto.mac(:sha256, Relay.Redacted.expose(key), timestamp <> token)
        |> Base.encode16(case: :lower)

      if Relay.Crypto.secure_compare(expected, String.downcase(given)),
        do: :ok,
        else: {:error, :bad_signature}
    else
      {:fresh, false} -> {:error, :stale_timestamp}
      _missing -> {:error, :missing_signature}
    end
  end

  def verify(_key, _body, _now), do: {:error, :missing_signature}

  # CH-39
  # CH-47
  @doc "Parses a Mailgun webhook body (decoded or as JSON text) into its event; an event Relay does not act on is `:ignored`."
  @spec events(binary() | map()) :: [Event.t()]
  def events(body) when is_binary(body), do: body |> Esp.json() |> events()

  def events(%{"event-data" => %{} = data}) do
    name = text(data["event"]) || "unknown"
    severity = text(data["severity"])
    status = if is_map(data["delivery-status"]), do: data["delivery-status"], else: %{}
    variables = if is_map(data["user-variables"]), do: data["user-variables"], else: %{}
    headers = get_in(data, ["message", "headers"]) || %{}

    {type, code} =
      case {name, severity} do
        {"delivered", _severity} -> {:delivered, "delivered"}
        {"failed", "permanent"} -> {:bounced, "failed:permanent"}
        {"failed", "temporary"} -> {:deferred, "failed:temporary"}
        {"complained", _severity} -> {:complained, "complained"}
        {"rejected", _severity} -> {:rejected, "rejected"}
        {engagement, _severity} when engagement in ["opened", "clicked", "unsubscribed"] ->
          {:engagement, engagement}

        {other, _severity} ->
          {:ignored, other}
      end

    [
      %Event{
        provider: "mailgun",
        type: type,
        code: code,
        id: text(data["id"]),
        delivery_id:
          Event.first_delivery_id([
            text(variables[Event.correlation_key()]),
            text(headers["message-id"])
          ]),
        provider_message_id: text(headers["message-id"]),
        recipient: Event.redact(data["recipient"]),
        occurred_at: Event.timestamp(data["timestamp"]),
        status: text(status["enhanced-code"]),
        diagnostic: Event.redact(text(status["message"]) || text(status["description"]))
      }
    ]
  end

  def events(_body), do: []

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
