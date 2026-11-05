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
        done: "You are unsubscribed."
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
        done: "Abonelikten çıktınız."
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
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Links.handler().describe(token) do
      {:ok, %{kind: kind} = link} ->
        text = copy(link.locale)[kind]

        form =
          ~s(<form method="post"><input type="hidden" name="confirm" value="yes">) <>
            ~s(<button type="submit">) <> escape(text.button) <> "</button></form>"

        page(conn, 200, link.locale, text.title, "<p>" <> escape(text.prompt) <> "</p>" <> form)

      {:error, :invalid} ->
        message(conn, 404, nil, :invalid)
    end
  end

  # CH-76
  # PC-35
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token} = params) do
    case {params, Links.handler().describe(token)} do
      {%{"List-Unsubscribe" => "One-Click"}, {:ok, %{kind: :unsubscribe}}} ->
        one_click(conn, token)

      {%{"List-Unsubscribe" => _value}, _link} ->
        send_resp(conn, 404, "")

      {%{"confirm" => "yes"}, {:ok, %{kind: kind} = link}} ->
        confirm(conn, token, kind, link.locale)

      {_params, {:error, :invalid}} ->
        message(conn, 404, nil, :invalid)

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
    case Links.handler().apply_link(token, evidence(conn, :confirmation_page)) do
      :ok ->
        text = copy(locale)[kind]
        page(conn, 200, locale, text.title, "<p>" <> escape(text.done) <> "</p>")

      {:error, reason} ->
        message(conn, status(reason), locale, reason)
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

  defp copy(locale), do: Map.get(@copy, locale || "en", @copy["en"])

  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, status, locale, title, body) do
    lang = if Map.has_key?(@copy, locale || ""), do: locale, else: "en"

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
