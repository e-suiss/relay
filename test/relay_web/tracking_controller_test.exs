defmodule RelayWeb.TrackingControllerTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Relay.Channels.Email
  alias Relay.Channels.Email.Tracking
  alias Relay.Channels.Email.Verp
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @endpoint RelayWeb.Endpoint
  @browser "Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0"

  defp forget do
    Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), "click_signals"})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    %{conn: build_conn()}
  end

  defp token(scope, id, target) do
    mac = Verp.key_function(Email.tracking_key_label(scope))
    {:ok, token} = Tracking.token(scope, id, target, mac)
    token
  end

  defp browser(conn), do: put_req_header(conn, "user-agent", @browser)

  describe "CH-43 CH-44 DS-30 click redirect" do
    test "CH-44: a signed click is a plain redirect and is recorded", %{conn: conn} do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      url = "https://shop.example/orders/42?ref=mail"
      conn = conn |> browser() |> get("/e/c/" <> token(scope, id, {:click, 1, url}))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == [url]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      {:ok, ledger} = Relay.Delivery.ledger(scope, id)
      assert Enum.any?(ledger, &(&1["event_type"] == "engagement.clicked"))
    end

    test "CH-43: a token Relay did not sign is not found and redirects nowhere", %{conn: conn} do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      forged = fn message -> {:ok, :crypto.mac(:hmac, :sha256, "forged", message)} end
      {:ok, token} = Tracking.token(scope, id, {:click, 1, "https://evil.example"}, forged)

      conn = conn |> browser() |> get("/e/c/" <> token)
      assert conn.status == 404
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "DS-32 open pixel" do
    test "DS-32: a GIF for any token; a signed open is recorded", %{conn: conn} do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      opened = conn |> browser() |> get("/e/o/" <> token(scope, id, :open))

      assert opened.status == 200
      assert ["image/gif"] = get_resp_header(opened, "content-type")
      assert "GIF89a" <> _rest = opened.resp_body

      {:ok, ledger} = Relay.Delivery.ledger(scope, id)
      assert Enum.any?(ledger, &(&1["event_type"] == "engagement.opened"))

      assert get(build_conn(), "/e/o/garbage").status == 200
    end
  end
end
