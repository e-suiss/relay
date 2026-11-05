defmodule RelayWeb.LinkControllerTest.Handler do
  @behaviour RelayWeb.Links

  @impl RelayWeb.Links
  def describe("unsub-" <> _rest), do: {:ok, %{kind: :unsubscribe, locale: "tr"}}
  def describe("pref-" <> _rest), do: {:ok, %{kind: :preference_change, locale: nil}}
  def describe("down-" <> _rest), do: {:ok, %{kind: :unsubscribe, locale: "en"}}
  def describe(_token), do: {:error, :invalid}

  @impl RelayWeb.Links
  def apply_link("down-" <> _rest, _evidence), do: {:error, :unavailable}

  def apply_link(token, evidence) do
    send(self(), {:applied, token, evidence})
    :ok
  end
end

defmodule RelayWeb.LinkControllerTest do
  use RelayWeb.ConnCase, async: false

  @form "application/x-www-form-urlencoded"

  setup do
    previous = Application.get_env(:relay, RelayWeb.Links)
    Application.put_env(:relay, RelayWeb.Links, handler: RelayWeb.LinkControllerTest.Handler)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, RelayWeb.Links, previous),
        else: Application.delete_env(:relay, RelayWeb.Links)
    end)
  end

  defp form_post(conn, path, body),
    do: conn |> put_req_header("content-type", @form) |> post(path, body)

  describe "CH-44 confirmation page" do
    test "CH-44: GET shows the confirmation page and changes nothing", %{conn: conn} do
      conn = get(conn, "/links/unsub-1")
      body = html_response(conn, 200)

      assert body =~ ~s(<html lang="tr">)
      assert body =~ "Abonelikten çık"
      assert body =~ ~s(<form method="post">)
      assert body =~ ~s(name="confirm" value="yes")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      refute_received {:applied, _token, _evidence}
    end

    test "CH-44: the page's POST applies the link with its evidence", %{conn: conn} do
      conn =
        conn
        |> put_req_header("user-agent", "Mail/1.0")
        |> form_post("/links/pref-2", "confirm=yes")

      assert html_response(conn, 200) =~ "Your preferences are updated."
      assert_received {:applied, "pref-2", evidence}
      assert evidence.source == :confirmation_page
      assert %DateTime{} = evidence.at
      assert Relay.Redacted.expose(evidence.user_agent) == "Mail/1.0"
      assert Relay.Redacted.expose(evidence.ip) == "127.0.0.1"
    end

    test "PC-35: an RFC 8058 one-click POST is applied directly, without a page", %{conn: conn} do
      conn = form_post(conn, "/links/unsub-3", "List-Unsubscribe=One-Click")

      assert response(conn, 200) == ""
      assert_received {:applied, "unsub-3", %{source: :rfc8058}}
    end

    test "PC-35: a multipart one-click POST is applied as well", %{conn: conn} do
      body =
        "--b\r\nContent-Disposition: form-data; name=\"List-Unsubscribe\"\r\n\r\n" <>
          "One-Click\r\n--b--\r\n"

      conn =
        conn
        |> put_req_header("content-type", "multipart/form-data; boundary=b")
        |> post("/links/unsub-4", body)

      assert response(conn, 200) == ""
      assert_received {:applied, "unsub-4", %{source: :rfc8058}}
    end

    test "PC-35: one-click works only for an unsubscribe link", %{conn: conn} do
      conn = form_post(conn, "/links/pref-5", "List-Unsubscribe=One-Click")

      assert response(conn, 404) == ""
      refute_received {:applied, _token, _evidence}
    end

    test "CH-44: an invalid link shows a page and applies nothing", %{conn: conn} do
      assert conn |> get("/links/nope") |> html_response(404) =~ "This link is not valid."

      conn = form_post(build_conn(), "/links/nope", "confirm=yes")
      assert html_response(conn, 404) =~ "This link is not valid."
      refute_received {:applied, _token, _evidence}
    end

    test "CH-44: a POST that is no confirmation and no one-click is refused", %{conn: conn} do
      conn = form_post(conn, "/links/unsub-6", "other=1")

      assert html_response(conn, 400) =~ "Bu bağlantı geçerli değil."
      refute_received {:applied, _token, _evidence}
    end

    test "CH-44: a handler that cannot apply now answers 503", %{conn: conn} do
      assert conn |> form_post("/links/down-7", "confirm=yes") |> html_response(503)
      one_click = form_post(build_conn(), "/links/down-7", "List-Unsubscribe=One-Click")
      assert response(one_click, 503) == ""
    end

    test "CH-44: without a configured handler every link is invalid", %{conn: conn} do
      Application.delete_env(:relay, RelayWeb.Links)
      assert conn |> get("/links/unsub-8") |> html_response(404)
    end
  end
end
