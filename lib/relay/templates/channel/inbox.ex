defmodule Relay.Templates.Channel.Inbox do
  @moduledoc """
  Inbox output (TP-9, TP-24, TP-29). An inbox variant is structured, never HTML: `"title"`, `"body"`, `"actions"` (a list of `%{"label" => ..., "url" => ...}`) and `"avatar"` (an `https` URL), all string keys. The payload carries `locale` and `dir` explicitly.

  The body is required; an action needs a label and a URL; a URL with the `javascript`, `data`, `vbscript` or `file` scheme is refused, and the avatar must be `https`. Invalid UTF-8 is removed and recorded (INV-1).
  """

  alias Relay.Templates.Direction
  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer

  @type action :: %{label: String.t(), url: String.t()}
  @type output :: %{
          title: String.t() | nil,
          body: String.t(),
          actions: [action()],
          avatar: String.t() | nil,
          locale: String.t() | nil,
          dir: String.t()
        }

  @refused_schemes ~w(javascript data vbscript file)

  # TP-9
  # TP-24
  # TP-29
  @doc "Cleans and checks the rendered fields; `opts` takes `:locale`."
  @spec render(map(), keyword()) ::
          {:ok, %{output: output(), changes: [Sanitizer.change()]}} | {:error, [Finding.t()]}
  def render(fields, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    {title, title_changes} = text(Map.get(fields, "title"), "title")
    {body, body_changes} = text(Map.get(fields, "body"), "body")
    {avatar, avatar_changes} = text(Map.get(fields, "avatar"), "avatar")
    {actions, action_changes, action_findings} = actions(Map.get(fields, "actions", []))

    found = body_findings(body) ++ avatar_findings(avatar) ++ action_findings

    findings =
      for {check, pointer} <- found,
          do: Finding.new(check, :hard, channel: :inbox, locale: locale, pointer: pointer)

    output = %{
      title: title,
      body: body || "",
      actions: actions,
      avatar: avatar,
      locale: locale,
      dir: Direction.attribute(locale)
    }

    changes = title_changes ++ body_changes ++ avatar_changes ++ action_changes
    if findings == [], do: {:ok, %{output: output, changes: changes}}, else: {:error, findings}
  end

  defp text(value, field) when is_binary(value), do: Sanitizer.utf8(value, field)
  defp text(_value, _field), do: {nil, []}

  defp body_findings(body) when is_binary(body) and body != "", do: []
  defp body_findings(_body), do: [{:inbox_body_missing, "/body"}]

  defp avatar_findings(nil), do: []

  defp avatar_findings(avatar) do
    if String.starts_with?(String.downcase(avatar), "https://"),
      do: [],
      else: [{:inbox_avatar_url, "/avatar"}]
  end

  defp actions(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce({[], [], []}, fn {action, index}, {kept, changes, findings} ->
      case action(action, index) do
        {:ok, clean, more} -> {kept ++ [clean], changes ++ more, findings}
        {:error, found} -> {kept, changes, findings ++ found}
      end
    end)
  end

  defp actions(_other), do: {[], [], [{:inbox_actions, "/actions"}]}

  defp action(%{"label" => label, "url" => url}, index)
       when is_binary(label) and is_binary(url) do
    path = "actions/#{index}"
    {label, label_changes} = Sanitizer.utf8(label, path <> "/label")
    {url, url_changes} = Sanitizer.utf8(url, path <> "/url")
    found = label_findings(label, path) ++ url_findings(url, path)

    if found == [],
      do: {:ok, %{label: label, url: url}, label_changes ++ url_changes},
      else: {:error, found}
  end

  defp action(_action, index), do: {:error, [{:inbox_action, "/actions/#{index}"}]}

  defp label_findings(label, path) do
    if String.trim(label) == "", do: [{:inbox_action_label, "/#{path}/label"}], else: []
  end

  defp url_findings(url, path) do
    if refused_url?(url), do: [{:inbox_action_url, "/#{path}/url"}], else: []
  end

  defp refused_url?(url) do
    parts = url |> String.trim() |> String.downcase() |> String.split(":", parts: 2)

    case parts do
      [_no_scheme] -> String.trim(url) == ""
      [scheme, _rest] -> String.replace(scheme, ~r/[\s\x00-\x1F]/, "") in @refused_schemes
    end
  end
end
