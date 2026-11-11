defmodule RelayWeb.Api.ExportTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery.Exports.Link
  alias Relay.Delivery.Exports.Store
  alias RelayTest.Api
  alias RelayTest.DeliveryFixture
  alias RelayTest.IngestFixture, as: F

  defp today, do: Relay.Clock.utc_now() |> DateTime.to_date()

  defp request!(token, kind, from \\ nil, to \\ nil) do
    from = from || today()
    to = to || Date.add(today(), 1)
    body = %{"kind" => kind, "from" => Date.to_iso8601(from), "to" => Date.to_iso8601(to)}
    F.body(F.request(:post, "/v1/exports", token, body), 202)
  end

  defp id(external), do: elem(Relay.ExternalId.decode(external, ["exp"]), 1)

  defp download(path), do: :get |> Api.conn(path, nil, []) |> Api.call(RelayWeb.Router)

  describe "DS-37 raw data exports" do
    test "DS-37, OP-39: a deliveries export is written as CSV and downloaded through its link" do
      %{scope: scope, delivery_id: delivery_id} = DeliveryFixture.sendable!()
      token = F.token(scope)
      requested = request!(token, "deliveries")

      assert %{"object" => "export", "state" => "pending", "download_path" => nil} = requested
      assert {:ok, :completed} = Relay.Delivery.run_export(scope, id(requested["id"]))

      ready = F.body(F.request(:get, "/v1/exports/" <> requested["id"], token), 200)
      assert %{"state" => "ready", "row_count" => 1, "download_path" => "/exports/" <> _} = ready

      conn = download(ready["download_path"])
      assert conn.status == 200
      assert ["text/csv" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"relay-deliveries-"
      assert ["no-store"] = Plug.Conn.get_resp_header(conn, "cache-control")

      [header, row, ""] = String.split(conn.resp_body, "\r\n")
      assert String.starts_with?(header, "id,created_at,notification_id,channel,provider,is_test")
      assert String.starts_with?(row, Relay.ExternalId.encode("dlv", delivery_id) <> ",")
      assert Base.encode16(:crypto.hash(:sha256, conn.resp_body), case: :lower) == ready["sha256"]

      listed = F.body(F.request(:get, "/v1/exports", token), 200)["data"]
      assert [%{"id" => listed_id}] = listed
      assert listed_id == requested["id"]
    end

    test "DS-37: a forged, moved or expired link is refused" do
      %{scope: scope} = DeliveryFixture.sendable!()
      requested = request!(F.token(scope), "delivery_events")
      {:ok, :completed} = Relay.Delivery.run_export(scope, id(requested["id"]))
      ready = F.body(F.request(:get, "/v1/exports/" <> requested["id"], F.token(scope)), 200)
      "/exports/" <> token = ready["download_path"]

      ["v1", payload, mac] = String.split(token, ".")
      forged = Enum.join(["v1", payload, String.reverse(mac)], ".")
      assert download("/exports/" <> forged).status == 404
      assert download("/exports/not-a-token").status == 404

      {:ok, expires_at, _offset} = DateTime.from_iso8601(ready["expires_at"])
      later = DateTime.add(expires_at, 1, :second)
      assert {:error, :expired} = Link.verify(token, later)

      {:ok, other} = Relay.Scope.new(scope.tenant_id, :test)
      {:ok, moved} = Link.sign(other, id(requested["id"]), expires_at)
      assert download("/exports/" <> moved).status == 404
    end

    test "DS-37: an export reads only its own tenant environment" do
      %{scope: mine} = DeliveryFixture.sendable!()
      %{scope: theirs} = DeliveryFixture.sendable!()
      requested = request!(F.token(mine), "deliveries")
      {:ok, :completed} = Relay.Delivery.run_export(mine, id(requested["id"]))

      path = "/v1/exports/" <> requested["id"]
      assert F.body(F.request(:get, path, F.token(theirs)), 404)["code"] == "export_not_found"

      assert F.body(F.request(:get, path, F.token(mine)), 200)["row_count"] == 1
    end

    test "DS-37: a period ends after it starts, covers at most 92 days and names a known kind" do
      %{scope: scope} = DeliveryFixture.sendable!()
      token = F.token(scope)
      day = Date.to_iso8601(today())
      far = Date.to_iso8601(Date.add(today(), 93))

      for body <- [
            %{"kind" => "deliveries", "from" => day, "to" => day},
            %{"kind" => "deliveries", "from" => day, "to" => far},
            %{"kind" => "addresses", "from" => day, "to" => far}
          ] do
        assert F.body(F.request(:post, "/v1/exports", token, body), 422)["code"] ==
                 "validation_failed"
      end
    end
  end

  describe "DS-37 CSV" do
    test "DS-37: fields are quoted by RFC 4180 and a formula is neutralised" do
      line = IO.iodata_to_binary(Store.csv_line(["a,b", "say \"hi\"", "=SUM(A1)", nil, 3, true]))
      assert line == ~s("a,b","say ""hi""",'=SUM(A1),,3,true\r\n)
    end
  end
end
