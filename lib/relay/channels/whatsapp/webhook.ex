defmodule Relay.Channels.Whatsapp.Webhook do
  @moduledoc """
  The inbound webhooks of the WhatsApp Cloud API (CH-60, CH-57, CH-61, PC-43).

    * `verify/3` checks `X-Hub-Signature-256` (`sha256=<hex>`, HMAC-SHA256 with the app secret) over the raw body, before anything is parsed, in constant time (CH-3, T-40).
    * `challenge/2` answers Meta's subscription check (`hub.mode=subscribe`, `hub.verify_token`, `hub.challenge`), comparing the token in constant time.
    * `parse/1` turns a verified body into items, one per change entry: message statuses (`Relay.Channels.Whatsapp.Status`), inbound messages that refresh the customer service window (CH-58), template status, category, quality and component changes (CH-57, TP-23), `account_update` with its `violation_type`, the marketing `user_preferences` of a recipient (PC-43) and messaging limit and throughput changes of a number (CH-61). A field Relay does not subscribe to is `{:ignored, field}`.
  """

  alias Relay.Channels.Whatsapp.Status

  @header "x-hub-signature-256"

  @type item ::
          {:status, map(), Status.event()}
          | {:inbound, map()}
          | {:template_status, map()}
          | {:template_category, map()}
          | {:template_quality, map()}
          | {:template_edit, map()}
          | {:account_update, map()}
          | {:user_preference, map()}
          | {:messaging_limit, map()}
          | {:ignored, String.t()}

  # CH-60
  # T-40
  @doc "Verifies the `X-Hub-Signature-256` signature of the raw body with the app secret."
  @spec verify(Relay.Redacted.t(), binary(), [{String.t(), String.t()}]) ::
          :ok | {:error, :missing_header | :bad_signature}
  def verify(app_secret, body, headers) when is_binary(body),
    do: Relay.Channels.Inbound.hmac(app_secret, body, headers, header: @header, prefix: "sha256=")

  @doc "Answers Meta's subscription check: the challenge when the mode is `subscribe` and the token matches."
  @spec challenge(map(), Relay.Redacted.t()) :: {:ok, String.t()} | :error
  def challenge(
        %{"hub.mode" => "subscribe", "hub.verify_token" => token, "hub.challenge" => value},
        verify_token
      )
      when is_binary(token) and is_binary(value) do
    expected = Relay.Redacted.expose(verify_token)

    if is_binary(expected) and Relay.Crypto.secure_compare(token, expected),
      do: {:ok, value},
      else: :error
  end

  def challenge(_params, _verify_token), do: :error

  # CH-60
  @doc "Parses a verified webhook body into its items; a body that is not a WhatsApp Business Account notification is `{:error, :invalid_body}`."
  @spec parse(binary() | map()) :: {:ok, [item()]} | {:error, :invalid_body}
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _reason} -> {:error, :invalid_body}
    end
  end

  def parse(%{"object" => "whatsapp_business_account", "entry" => entries})
      when is_list(entries) do
    items =
      for %{} = entry <- entries,
          %{"field" => field, "value" => %{} = value} <- list(entry["changes"]),
          item <- items(field, value, string(entry["id"])),
          do: item

    {:ok, items}
  end

  def parse(_body), do: {:error, :invalid_body}

  defp items("messages", value, waba_id) do
    number = number(value, waba_id)

    statuses =
      for %{} = entry <- list(value["statuses"]) do
        case Status.normalize(entry) do
          {:ok, event} -> {:status, number, event}
          :ignored -> {:ignored, "statuses"}
        end
      end

    inbound =
      for %{"from" => from, "id" => id, "timestamp" => ts} = message <- list(value["messages"]),
          is_binary(from) and is_binary(id),
          {:ok, at} <- [Status.timestamp(ts)] do
        {:inbound,
         Map.merge(number, %{
           wa_id: from,
           message_id: id,
           at: at,
           type: string(message["type"]),
           button_payload: button_payload(message["button"])
         })}
      end

    statuses ++ inbound
  end

  defp items("message_template_status_update", value, waba_id) do
    [
      {:template_status,
       Map.merge(template(value, waba_id), %{
         event: string(value["event"]),
         reason: reason(value)
       })}
    ]
  end

  defp items("template_category_update", value, waba_id) do
    [
      {:template_category,
       Map.merge(template(value, waba_id), %{
         previous_category: category(value["previous_category"]),
         new_category: category(value["new_category"]),
         correct_category: category(value["correct_category"])
       })}
    ]
  end

  defp items("message_template_components_update", value, waba_id) do
    components =
      [
        {"HEADER", value["message_template_title"]},
        {"BODY", value["message_template_element"]},
        {"FOOTER", value["message_template_footer"]}
      ]
      |> Enum.filter(fn {_type, text} -> is_binary(text) end)
      |> Enum.map(fn {type, text} -> %{"type" => type, "text" => text} end)

    [{:template_edit, Map.put(template(value, waba_id), :components, components)}]
  end

  defp items("message_template_quality_update", value, waba_id) do
    [
      {:template_quality,
       Map.merge(template(value, waba_id), %{
         previous_quality: string(value["previous_quality_score"]),
         new_quality: string(value["new_quality_score"])
       })}
    ]
  end

  defp items("account_update", value, waba_id) do
    [
      {:account_update,
       %{
         waba_id: waba_id,
         event: string(value["event"]),
         violation_type: string(get_in(value, ["violation_info", "violation_type"])),
         phone_number: string(value["phone_number"])
       }}
    ]
  end

  defp items("user_preferences", value, waba_id) do
    number = number(value, waba_id)

    for %{"wa_id" => wa_id, "category" => "marketing_messages", "value" => choice} = entry <-
          list(value["user_preferences"]),
        is_binary(wa_id),
        choice in ["stop", "resume"],
        {:ok, at} <- [Status.timestamp(entry["timestamp"])] do
      {:user_preference,
       Map.merge(number, %{wa_id: wa_id, value: choice(choice), at: at})}
    end
  end

  defp items("phone_number_quality_update", value, waba_id) do
    [
      {:messaging_limit,
       %{
         waba_id: waba_id,
         phone_number: string(value["display_phone_number"]),
         event: string(value["event"]),
         limit:
           string(value["max_daily_conversations_per_business"]) ||
             string(value["current_limit"])
       }}
    ]
  end

  defp items("business_capability_update", value, waba_id) do
    limit =
      value["max_daily_conversations_per_business"] || value["max_daily_conversation_per_phone"]

    [
      {:messaging_limit,
       %{waba_id: waba_id, phone_number: nil, event: "CAPABILITY_UPDATE", limit: limit(limit)}}
    ]
  end

  defp items(field, _value, _waba_id), do: [{:ignored, to_string(field)}]

  defp number(value, waba_id) do
    %{
      waba_id: waba_id,
      phone_number_id: string(get_in(value, ["metadata", "phone_number_id"]))
    }
  end

  defp template(value, waba_id) do
    %{
      waba_id: waba_id,
      template_id: id(value["message_template_id"]),
      name: string(value["message_template_name"]),
      language: string(value["message_template_language"])
    }
  end

  defp reason(value) do
    case string(value["reason"]) do
      nil -> nil
      "NONE" -> nil
      reason -> reason
    end
  end

  defp choice("stop"), do: :stop
  defp choice("resume"), do: :resume

  defp button_payload(%{"payload" => payload}) when is_binary(payload), do: payload
  defp button_payload(_button), do: nil

  defp category(value) when is_binary(value), do: String.downcase(value)
  defp category(_value), do: nil

  defp limit(value) when is_integer(value), do: Integer.to_string(value)
  defp limit(value) when is_binary(value), do: value
  defp limit(_value), do: nil

  defp id(value) when is_integer(value), do: Integer.to_string(value)
  defp id(value) when is_binary(value), do: value
  defp id(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
