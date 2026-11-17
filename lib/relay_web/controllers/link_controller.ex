defmodule RelayWeb.LinkController do
  @moduledoc false

  use RelayWeb, :controller

  alias Relay.Redacted
  alias RelayWeb.Links

  @copy %{
    "en" => %{
      unsubscribe: %{
        title: "Unsubscribe",
        prompt: "Stop these e-mails?",
        button: "Unsubscribe",
        done: "You are unsubscribed.",
        manage: "Manage my preferences",
        brand_prompt: "You can also refuse every commercial e-mail from this brand.",
        brand_button: "I want no commercial e-mail from this brand at all",
        refused: "You will receive no commercial e-mail from this brand."
      },
      preference_change: %{
        title: "Confirm the change",
        prompt: "Apply this change to your notification preferences?",
        button: "Confirm",
        done: "Your preferences are updated."
      },
      address_verification: %{
        title: "Confirm your address",
        prompt: "Confirm this e-mail address?",
        button: "Confirm",
        done: "Your address is confirmed."
      },
      invalid: "This link is not valid.",
      unavailable: "This link cannot be used right now. Please try again later."
    },
    "tr" => %{
      unsubscribe: %{
        title: "Abonelikten çık",
        prompt: "Bu e-postaları artık almak istemiyor musunuz?",
        button: "Abonelikten çık",
        done: "Abonelikten çıktınız.",
        manage: "Tercihlerimi yönet",
        brand_prompt: "Bu markanın bütün ticari e-postalarını da reddedebilirsiniz.",
        brand_button: "Bu markadan hiç ticari e-posta almak istemiyorum",
        refused: "Bu markadan artık ticari e-posta almayacaksınız."
      },
      preference_change: %{
        title: "Değişikliği onaylayın",
        prompt: "Bildirim tercihlerinizdeki bu değişiklik uygulansın mı?",
        button: "Onayla",
        done: "Tercihleriniz güncellendi."
      },
      address_verification: %{
        title: "Adresinizi onaylayın",
        prompt: "Bu e-posta adresini onaylıyor musunuz?",
        button: "Onayla",
        done: "Adresiniz onaylandı."
      },
      invalid: "Bu bağlantı geçerli değil.",
      unavailable: "Bu bağlantı şu anda kullanılamıyor. Lütfen daha sonra yeniden deneyin."
    }
  }

  # CH-76
  # CH-44
  # PC-36
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Links.handler().describe(token) do
      {:ok, %{kind: :unsubscribe, state: :unsubscribed} = link} ->
        unsubscribed(conn, link.locale)

      {:ok, %{kind: :unsubscribe, state: :refused} = link} ->
        refused(conn, link.locale)

      {:ok, %{kind: kind} = link} ->
        text = copy(link.locale)[kind]

        form =
          ~s(<form method="post"><input type="hidden" name="confirm" value="yes">) <>
            ~s(<button type="submit">) <> escape(text.button) <> "</button></form>"

        page(conn, 200, link.locale, text.title, "<p>" <> escape(text.prompt) <> "</p>" <> form)

      {:error, reason} ->
        message(conn, status(reason), nil, reason)
    end
  end

  # CH-76
  # PC-35
  # PC-36
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token, "refuse" => "yes"}) do
    handler = Links.handler()

    case handler.describe(token) do
      {:ok, %{kind: :unsubscribe} = link} -> refuse(conn, handler, token, link.locale)
      {:ok, link} -> message(conn, 400, link.locale, :invalid)
      {:error, reason} -> message(conn, status(reason), nil, reason)
    end
  end

  def create(conn, %{"token" => token} = params) do
    case {params, Links.handler().describe(token)} do
      {%{"List-Unsubscribe" => "One-Click"}, {:ok, %{kind: :unsubscribe}}} ->
        one_click(conn, token)

      {%{"List-Unsubscribe" => "One-Click"}, {:error, :unavailable}} ->
        send_resp(conn, 503, "")

      {%{"List-Unsubscribe" => _value}, _link} ->
        send_resp(conn, 404, "")

      {%{"confirm" => "yes"}, {:ok, %{kind: kind} = link}} ->
        confirm(conn, token, kind, link.locale)

      {_params, {:error, reason}} ->
        message(conn, status(reason), nil, reason)

      {_params, {:ok, link}} ->
        message(conn, 400, link.locale, :invalid)
    end
  end

  defp one_click(conn, token) do
    case Links.handler().apply_link(token, evidence(conn, :rfc8058)) do
      :ok -> send_resp(conn, 200, "")
      {:error, reason} -> send_resp(conn, status(reason), "")
    end
  end

  defp confirm(conn, token, kind, locale) do
    case {Links.handler().apply_link(token, evidence(conn, :confirmation_page)), kind} do
      {:ok, :unsubscribe} ->
        unsubscribed(conn, locale)

      {:ok, kind} ->
        text = copy(locale)[kind]
        page(conn, 200, locale, text.title, "<p>" <> escape(text.done) <> "</p>")

      {{:error, reason}, _kind} ->
        message(conn, status(reason), locale, reason)
    end
  end

  # PC-36
  # PC-38
  defp refuse(conn, handler, token, locale) do
    applied =
      if function_exported?(handler, :refuse, 2),
        do: handler.refuse(token, evidence(conn, :unsubscribe_page)),
        else: {:error, :invalid}

    case applied do
      :ok -> refused(conn, locale)
      {:error, reason} -> message(conn, status(reason), locale, reason)
    end
  end

  # PC-36
  # X-22
  defp unsubscribed(conn, locale) do
    text = copy(locale).unsubscribe

    form = ~s(<form method="post"><input type="hidden" name="refuse" value="yes">)
    button = ~s(<button type="submit">) <> escape(text.brand_button) <> "</button></form>"
    brand = "<p>" <> escape(text.brand_prompt) <> "</p>" <> form <> button
    body = "<p>" <> escape(text.done) <> "</p>" <> manage(text) <> brand
    page(conn, 200, locale, text.title, body)
  end

  defp refused(conn, locale) do
    text = copy(locale).unsubscribe
    body = "<p>" <> escape(text.refused) <> "</p>" <> manage(text)
    page(conn, 200, locale, text.title, body)
  end

  defp manage(text) do
    case Links.preferences_url() do
      "https://" <> _rest = url ->
        link = ~s(<a rel="noreferrer" href=") <> escape(url) <> ~s(">)
        "<p>" <> link <> escape(text.manage) <> "</a></p>"

      _none ->
        ""
    end
  end

  defp status(:invalid), do: 404
  defp status(:unavailable), do: 503

  defp evidence(conn, source) do
    user_agent =
      case get_req_header(conn, "user-agent") do
        [value | _rest] -> Redacted.wrap(value)
        [] -> nil
      end

    %{
      source: source,
      at: Relay.Clock.utc_now(),
      ip: Redacted.wrap(conn.remote_ip |> :inet.ntoa() |> to_string()),
      user_agent: user_agent
    }
  end

  defp message(conn, status, locale, key), do: page(conn, status, locale, copy(locale)[key], "")

  defp copy(locale), do: Map.fetch!(@copy, language(locale))

  defp language(locale) when is_binary(locale) do
    language = locale |> String.split("-") |> hd() |> String.downcase()
    if is_map_key(@copy, language), do: language, else: "en"
  end

  defp language(_locale), do: "en"

  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, status, locale, title, body) do
    lang = language(locale)

    html = """
    <!doctype html>
    <html lang="#{lang}">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title>#{escape(title)}</title>
    <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.5}button{font:inherit;padding:.5rem 1rem}</style>
    </head>
    <body>
    <h1>#{escape(title)}</h1>
    #{body}
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp escape(text), do: Plug.HTML.html_escape(text)
end
