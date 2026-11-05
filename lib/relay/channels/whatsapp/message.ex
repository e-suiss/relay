defmodule Relay.Channels.Whatsapp.Message do
  @moduledoc """
  The WhatsApp Cloud API message body of one send (CH-57, CH-58, CH-60).

    * A rendered WhatsApp cell (`template_name`, `language`, `parameters`) is a template message: the approved Meta template by name and language, with its body parameters. Numeric parameter names are positional and sent in number order; other names are named parameters (`parameter_name`). Meta does not accept both in one template, so mixed names are refused.
    * Content with `text` is a free-form text message, which only an open customer service window allows (CH-58).
    * When content offers both, `kind` (`"template"` or `"free_form"`) names the one the channel step chose (`Relay.Channels.Whatsapp.Window.choose/2`); without it the template is sent. This module builds the body only and decides nothing.

  Every message carries the correlation of its attempt in `biz_opaque_callback_data`, which Meta echoes in the status webhooks: the send endpoint has no idempotency key, so Relay correlates and deduplicates itself (CH-60).
  """

  @prefix "rly1"
  @numeric ~r/\A[1-9][0-9]{0,2}\z/

  @type kind :: :template | :free_form

  # CH-58
  @doc "The message kinds a content offers, the template first."
  @spec kinds(map()) :: [kind()]
  def kinds(content) when is_map(content) do
    template = if text?(content["template_name"]), do: [:template], else: []
    free_form = if text?(content["text"]), do: [:free_form], else: []
    template ++ free_form
  end

  def kinds(_content), do: []

  # CH-58
  @doc "The kind a content is sent as: the chosen `kind` when the content offers it, else the template, else free-form text."
  @spec kind(map()) :: {:ok, kind()} | {:error, :invalid_content}
  def kind(content) do
    offered = kinds(content)

    chosen =
      case content do
        %{"kind" => "template"} -> :template
        %{"kind" => "free_form"} -> :free_form
        _none -> List.first(offered)
      end

    if chosen in offered, do: {:ok, chosen}, else: {:error, :invalid_content}
  end

  # CH-57
  # CH-60
  @doc "Builds the request body of a message to the WhatsApp user `to` (E.164) with the attempt's correlation."
  @spec body(map(), String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_content}
  def body(content, to, correlation) when is_binary(to) and is_binary(correlation) do
    with {:ok, kind} <- kind(content),
         {:ok, part} <- part(kind, content) do
      base = %{
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => to,
        "biz_opaque_callback_data" => correlation
      }

      {:ok, Map.merge(base, part)}
    end
  end

  defp part(:free_form, content),
    do: {:ok, %{"type" => "text", "text" => %{"preview_url" => false, "body" => content["text"]}}}

  defp part(:template, content) do
    with {:ok, language} <- language(content["language"]),
         {:ok, parameters} <- parameters(content["parameters"] || []) do
      template = %{"name" => content["template_name"], "language" => %{"code" => language}}

      template =
        case parameters do
          [] -> template
          list -> Map.put(template, "components", [%{"type" => "body", "parameters" => list}])
        end

      {:ok, %{"type" => "template", "template" => template}}
    end
  end

  # CH-57
  @doc "The Meta language code of a Relay locale: `tr` stays `tr`, `en-US` becomes `en_US`."
  @spec language(term()) :: {:ok, String.t()} | {:error, :invalid_content}
  def language(locale) when is_binary(locale) and byte_size(locale) in 2..35,
    do: {:ok, String.replace(locale, "-", "_")}

  def language(_locale), do: {:error, :invalid_content}

  defp parameters(list) when is_list(list) do
    if Enum.all?(list, &parameter?/1), do: ordered(list), else: {:error, :invalid_content}
  end

  defp parameters(_other), do: {:error, :invalid_content}

  defp parameter?(%{"name" => name, "value" => value}), do: text?(name) and is_binary(value)
  defp parameter?(_other), do: false

  defp ordered(list) do
    case Enum.split_with(list, &Regex.match?(@numeric, &1["name"])) do
      {numeric, []} ->
        sorted = Enum.sort_by(numeric, &String.to_integer(&1["name"]))
        {:ok, Enum.map(sorted, &%{"type" => "text", "text" => &1["value"]})}

      {[], named} ->
        {:ok,
         Enum.map(
           named,
           &%{"type" => "text", "parameter_name" => &1["name"], "text" => &1["value"]}
         )}

      _mixed ->
        {:error, :invalid_content}
    end
  end

  # CH-60
  @doc "The correlation of an attempt, sent in `biz_opaque_callback_data`."
  @spec correlation(Relay.Id.t(), pos_integer()) :: String.t()
  def correlation(delivery_id, attempt_no) when is_integer(attempt_no) and attempt_no > 0,
    do: Enum.join([@prefix, Relay.Id.to_string(delivery_id), attempt_no], ".")

  # CH-60
  @doc "Reads the delivery and attempt back from a correlation; anything Relay did not write is `:error`."
  @spec parse_correlation(term()) :: {:ok, Relay.Id.t(), pos_integer()} | :error
  def parse_correlation(value) when is_binary(value) do
    with [@prefix, id, n] <- String.split(value, "."),
         {:ok, delivery_id} <- Relay.Id.parse(id),
         {attempt_no, ""} when attempt_no > 0 <- Integer.parse(n) do
      {:ok, delivery_id, attempt_no}
    else
      _other -> :error
    end
  end

  def parse_correlation(_value), do: :error

  defp text?(value), do: is_binary(value) and value != ""
end
