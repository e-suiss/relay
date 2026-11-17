defmodule RelayWeb.ResponseLinkController do
  @moduledoc false

  use RelayWeb, :controller

  alias Relay.Api.WaitpointResponses

  @copy %{
    "en" => %{
      title: "Your response",
      prompt: "Choose your response.",
      processing: "Your response is received and is being processed.",
      responded: "Your response is recorded.",
      not_awaited: "A response is no longer awaited.",
      refused: "This response cannot be given here.",
      invalid: "This link is not valid.",
      unavailable: "This link cannot be used right now. Please try again later."
    },
    "tr" => %{
      title: "Yanıtınız",
      prompt: "Yanıtınızı seçin.",
      processing: "Yanıtınız alındı, işleniyor.",
      responded: "Yanıtınız kaydedildi.",
      not_awaited: "Artık yanıt beklenmiyor.",
      refused: "Bu yanıt buradan verilemiyor.",
      invalid: "Bu bağlantı geçerli değil.",
      unavailable: "Bu bağlantı şu anda kullanılamıyor. Lütfen daha sonra yeniden deneyin."
    }
  }

  # AG-31
  # AG-35
  # AG-29
  # CH-44
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case WaitpointResponses.link(token) do
      {:ok, %{state: :open, actions: actions}} ->
        text = copy(conn)
        forms = Enum.map_join(actions, "", &form/1)
        page(conn, 200, "<p>" <> escape(text.prompt) <> "</p>" <> forms)

      {:ok, %{state: state}} ->
        message(conn, 200, state)

      {:error, reason} ->
        message(conn, status(reason), reason)
    end
  end

  # AG-35
  # AG-28
  # INV-31
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token} = params) do
    case WaitpointResponses.choose(token, params["action"]) do
      {:ok, state} -> message(conn, 200, state)
      {:error, reason} -> message(conn, status(reason), reason)
    end
  end

  defp form(%{"id" => id, "label" => label}) do
    hidden = ~s(<input type="hidden" name="action" value=") <> escape(id) <> ~s(">)
    button = ~s(<button type="submit">) <> escape(label) <> "</button>"
    ~s(<form method="post">) <> hidden <> button <> "</form>"
  end

  defp form(_action), do: ""

  defp status(:invalid), do: 404
  defp status(:refused), do: 400
  defp status(:unavailable), do: 503

  defp message(conn, status, key),
    do: page(conn, status, "<p>" <> escape(copy(conn)[key]) <> "</p>")

  defp copy(conn), do: Map.fetch!(@copy, language(conn))

  defp language(conn) do
    case get_req_header(conn, "accept-language") do
      ["tr" <> _rest | _more] -> "tr"
      _other -> "en"
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, status, body) do
    title = escape(copy(conn).title)

    html = """
    <!doctype html>
    <html lang="#{language(conn)}">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title>#{title}</title>
    <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.5}button{font:inherit;padding:.5rem 1rem;margin:.25rem 0}</style>
    </head>
    <body>
    <h1>#{title}</h1>
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
