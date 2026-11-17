defmodule Relay.Agents.Live.Request do
  @moduledoc """
  The decision request as a human sees it, pure (INV-33, AG-29, AG-32, AG-33, AG-34, AG-35). The text is produced here, on the server, from the typed `content` fields of the waitpoint: each field is one row of its name and its value as plain text. The agent's free text is never part of that text: it is a field of its own under the label "the agent's claim". Every value enters the render as a variable of a fixed source, so the template engine escapes it for its channel and neither Markdown nor HTML of a sender is ever interpreted.

  `build/1` returns, for one channel, the source cell and its variables for `Relay.Templates.render_cell/1`, the links and what the inbox item adds: its typed data rows and the group key that makes every copy of one request the same item.

    * The sender type (`human`, `system` or `agent`) is shown on every surface (AG-34): the subtitle of a push, a line of an e-mail and an SMS, a data row of the inbox item.
    * A push is only an invitation (AG-33): it carries no action, so nothing is answered from a lock screen, and its lock screen text is neutral (CH-67); the fields are shown after the device is unlocked.
    * An approval-type request (AG-32, IN-6, E-16) has one action on every surface, the deep link to the Access approval surface, and never a response link.
    * A response link is given only for a human channel (AG-30); the inbox item, which a subscriber session answers, never carries one.
    * The copy that closes a request says that it no longer awaits a response and carries no action (AG-35).
  """

  @max_rows 20
  @max_label 64
  @max_value 500
  @inbox Relay.Limits.fetch!(["inbox"])

  @texts %{
    "en" => %{
      question: "Decision request",
      review: "Review request",
      approval: "Approval request",
      neutral: "A request is waiting for your response.",
      approval_neutral: "A request is waiting for your decision on the approval page.",
      agent: "Sent by an agent",
      system: "Sent by a system",
      human: "Sent by a person",
      claim: "The agent's claim (not verified)",
      respond: "Respond",
      approve: "Open the approval page",
      closed: "Request closed",
      closed_body: "This request is no longer awaiting a response."
    },
    "tr" => %{
      question: "Karar isteği",
      review: "İnceleme isteği",
      approval: "Onay isteği",
      neutral: "Yanıtınızı bekleyen bir istek var.",
      approval_neutral: "Onay sayfasında kararınızı bekleyen bir istek var.",
      agent: "Bir ajan gönderdi",
      system: "Bir sistem gönderdi",
      human: "Bir kişi gönderdi",
      claim: "Ajanın iddiası (doğrulanmadı)",
      respond: "Yanıtla",
      approve: "Onay sayfasını aç",
      closed: "İstek kapandı",
      closed_body: "Bu istek için artık yanıt beklenmiyor."
    }
  }

  @type input :: %{
          required(:channel) => atom(),
          required(:copy) => :invitation | :closed,
          required(:locale) => String.t() | nil,
          required(:interaction) => String.t(),
          required(:approval) => boolean(),
          required(:sender_type) => String.t(),
          required(:waitpoint) => String.t(),
          optional(:state) => String.t(),
          optional(:content) => map(),
          optional(:claim) => String.t() | nil,
          optional(:access_link) => String.t() | nil,
          optional(:response_link) => String.t() | nil
        }

  @type built :: %{
          cell: map(),
          data: %{String.t() => String.t()},
          links: %{String.t() => String.t()},
          locale: String.t(),
          rows: [%{String.t() => String.t()}],
          group_key: String.t()
        }

  # AG-29
  @doc "The locale the request is written in: Turkish for a Turkish locale, English for every other."
  @spec locale(String.t() | nil) :: String.t()
  def locale(tag) when is_binary(tag) do
    case tag |> String.downcase() |> String.split(["-", "_"]) do
      ["tr" | _rest] -> "tr"
      _other -> "en"
    end
  end

  def locale(_none), do: "en"

  # AG-29
  @doc "The rows of a waitpoint's typed `content`, in the order of their names: each field's name and its value as plain text, at most #{@max_rows} of them."
  @spec rows(map() | term()) :: [{String.t(), String.t()}]
  def rows(%{} = content) do
    content
    |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
    |> Enum.take(@max_rows)
    |> Enum.map(fn {name, value} -> {cut(to_string(name), @max_label), cut(plain(value))} end)
  end

  def rows(_other), do: []

  defp plain(value) when is_binary(value), do: value
  defp plain(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp plain(nil), do: ""
  defp plain(value), do: Jason.encode!(value)

  defp cut(text, limit \\ @max_value), do: String.slice(text, 0, limit)

  # INV-33
  # AG-29
  # AG-32
  # AG-33
  # AG-34
  # AG-35
  @doc "Builds the cell, the variables, the links and the inbox additions of one copy of a request for one channel; see the module documentation."
  @spec build(input()) :: built()
  def build(%{channel: channel, copy: copy} = input) do
    locale = locale(input.locale)
    texts = Map.fetch!(@texts, locale)
    rows = if copy == :invitation, do: rows(Map.get(input, :content, %{})), else: []
    claim = if copy == :invitation, do: claim(Map.get(input, :claim)), else: nil
    link = link(input, texts, channel)

    base = %{
      "heading" => heading(input, texts),
      "neutral" => neutral(input, texts),
      "sender" => sender(input.sender_type, texts),
      "summary" => summary(input, texts, rows)
    }

    data =
      base
      |> Map.merge(row_data(rows))
      |> put_present("claim_label", claim && texts.claim)
      |> put_present("claim", claim)
      |> put_present("link", link && elem(link, 1))
      |> put_present("link_label", link && elem(link, 0))

    %{
      cell: cell(channel, length(rows), claim != nil, link != nil),
      data: data,
      links: links(link),
      locale: locale,
      rows: item_rows(input, rows, claim),
      group_key: "waitpoint:" <> input.waitpoint
    }
  end

  defp claim(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _present -> text
    end
  end

  defp claim(_none), do: nil

  defp heading(%{copy: :closed}, texts), do: texts.closed
  defp heading(%{approval: true}, texts), do: texts.approval
  defp heading(%{interaction: "review"}, texts), do: texts.review
  defp heading(_question, texts), do: texts.question

  defp neutral(%{copy: :closed}, texts), do: texts.closed_body
  defp neutral(%{approval: true}, texts), do: texts.approval_neutral
  defp neutral(_input, texts), do: texts.neutral

  # AG-34
  defp sender("agent", texts), do: texts.agent
  defp sender("human", texts), do: texts.human
  defp sender(_system, texts), do: texts.system

  defp summary(%{copy: :closed}, texts, _rows), do: texts.closed_body
  defp summary(input, texts, []), do: neutral(input, texts)
  defp summary(_input, _texts, rows), do: Enum.map_join(rows, " · ", &join/1)

  defp join({label, value}), do: label <> ": " <> value

  # AG-30
  # AG-32
  defp link(%{copy: :closed}, _texts, _channel), do: nil

  defp link(%{approval: true} = input, texts, _channel) do
    case Map.get(input, :access_link) do
      url when is_binary(url) -> {texts.approve, url}
      _none -> nil
    end
  end

  defp link(_input, _texts, :in_app), do: nil

  defp link(input, texts, _channel) do
    case Map.get(input, :response_link) do
      url when is_binary(url) -> {texts.respond, url}
      _none -> nil
    end
  end

  defp links({_label, url}), do: %{"primary" => url}
  defp links(nil), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp row_data(rows) do
    for {{label, value}, index} <- Enum.with_index(rows),
        {name, text} <- [{"label_#{index}", label}, {"value_#{index}", value}],
        into: %{},
        do: {name, text}
  end

  # AG-33
  # CH-67
  defp cell(channel, _rows, _claim?, _link?) when channel in [:push, :web_push] do
    %{
      "title" => "{{ heading }}",
      "subtitle" => "{{ sender }}",
      "lock_screen_body" => "{{ neutral }}",
      "in_app_body" => "{{ summary }}"
    }
  end

  defp cell(:sms, _rows, _claim?, link?) do
    link = if link?, do: " {{ link }}", else: ""
    %{"body" => "{{ heading }} ({{ sender }}): {{ neutral }}" <> link}
  end

  # AG-32
  # IN-6
  defp cell(:in_app, _rows, _claim?, link?) do
    actions = if link?, do: [%{"label" => "{{ link_label }}", "url" => "{{ link }}"}], else: []
    %{"title" => "{{ heading }}", "body" => "{{ neutral }}", "actions" => actions}
  end

  defp cell(_email, rows, claim?, link?) do
    %{
      "html_kind" => "raw_html",
      "subject" => "{{ heading }}",
      "preheader" => "{{ neutral }}",
      "html" => html(rows, claim?, link?),
      "text" => text(rows, claim?, link?)
    }
  end

  defp text(rows, claim?, link?) do
    lines =
      ["{{ heading }}", "{{ sender }}", "", "{{ neutral }}", ""] ++
        for(index <- indexes(rows), do: "{{ label_#{index} }}: {{ value_#{index} }}") ++
        if(claim?, do: ["", "{{ claim_label }}:", "{{ claim }}"], else: []) ++
        if(link?, do: ["", "{{ link_label }}: {{ link }}"], else: [])

    Enum.join(lines, "\n")
  end

  defp html(rows, claim?, link?) do
    table =
      for index <- indexes(rows),
          do: "<tr><th>{{ label_#{index} }}</th><td>{{ value_#{index} }}</td></tr>"

    quoted = "<p>{{ claim_label }}:</p><blockquote>{{ claim }}</blockquote>"
    claim = if claim?, do: quoted, else: ""
    link = if link?, do: ~s(<p><a href="{{ link }}">{{ link_label }}</a></p>), else: ""

    IO.iodata_to_binary([
      ~s(<!doctype html><html><head><meta charset="utf-8">),
      ~s(<meta name="color-scheme" content="light dark"></head><body>),
      "<h1>{{ heading }}</h1><p>{{ sender }}</p><p>{{ neutral }}</p>",
      "<table>",
      table,
      "</table>",
      claim,
      link,
      "</body></html>"
    ])
  end

  defp indexes(0), do: []
  defp indexes(rows), do: Enum.to_list(0..(rows - 1))

  # AG-29
  # AG-34
  # AG-35
  defp item_rows(input, rows, claim) do
    awaiting = input.copy == :invitation

    fixed =
      [
        {"waitpoint", Relay.ExternalId.encode("wp", parse!(input.waitpoint))},
        {"interaction", input.interaction},
        {"sender_type", input.sender_type},
        {"awaiting_response", to_string(awaiting)}
      ] ++ if(awaiting, do: [], else: [{"state", Map.get(input, :state, "closed")}])

    typed = for {label, value} <- rows, do: {"content." <> label, value}
    claimed = if claim, do: [{"agent_claim", claim}], else: []

    (fixed ++ claimed ++ typed)
    |> Enum.take(@inbox["data_rows_max"])
    |> Enum.map(fn {key, value} ->
      %{
        "key" => bytes(key, @inbox["data_key_max_bytes"]),
        "value" => bytes(value, @inbox["data_value_max_bytes"])
      }
    end)
  end

  defp parse!(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end

  defp bytes(text, max) when byte_size(text) <= max, do: text

  defp bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, kept ->
      if byte_size(kept) + byte_size(grapheme) <= max,
        do: {:cont, kept <> grapheme},
        else: {:halt, kept}
    end)
  end
end
