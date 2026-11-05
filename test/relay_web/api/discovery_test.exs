defmodule RelayWeb.Api.DiscoveryTest do
  use Relay.DataCase, async: true

  import Plug.Conn

  alias Relay.Api.Contract
  alias Relay.Api.Discovery
  alias Relay.Api.Schema
  alias RelayTest.Api
  alias RelayWeb.Api.Response

  defp get_document(path) do
    conn = :get |> Api.conn(path) |> Api.call(RelayWeb.Router)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp routed do
    RelayWeb.Router |> Api.coverage() |> Map.fetch!(:served)
  end

  describe "E-81 Relay discovery document" do
    test "E-81: the document is served unauthenticated and follows the contract" do
      {conn, _document} = get_document("/.well-known/relay-configuration")

      assert conn.status == 200
      Api.assert_contract(conn)
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "E-81, E-90: issuer, API base, region, Access link and versions are the installation's" do
      {_conn, document} = get_document("/.well-known/relay-configuration")
      issuer = String.trim_trailing(Response.base_url(), "/")
      versions = Contract.api_versions()

      assert document["issuer"] == issuer
      assert document["api_base"] == issuer <> "/v1"
      assert document["jwks_uri"] == issuer <> "/.well-known/relay-jwks.json"
      assert document["region"] == Relay.Datasets.installation_region()
      assert document["region"] in ["tr", "eu", "us"]
      assert document["access_issuer"] == Relay.Access.issuer()
      assert document["access_client_id"] == Relay.Access.client_id()
      assert document["contract_version"] == versions.latest
      assert document["contract_versions_supported"] == versions.supported
    end

    test "E-81: only capabilities whose operations are all routed appear, with their endpoints" do
      {_conn, document} = get_document("/.well-known/relay-configuration")
      served = routed()
      issuer = document["issuer"]

      for capability <- Discovery.capabilities() do
        offered? = Enum.all?(capability.operations, &(&1 in served))
        assert offered? == capability.urn in document["capabilities"], capability.urn

        if offered?,
          do: assert(document[capability.field] == issuer <> capability.path),
          else: refute(Map.has_key?(document, capability.field))
      end

      assert "urn:suiss:relay:events:1" in document["capabilities"]
      assert document["events_endpoint"] == issuer <> "/v1/events"
      refute "urn:suiss:relay:waitpoint:1" in document["capabilities"]
      refute Map.has_key?(document, "waitpoints_endpoint")
    end

    test "E-81: a capability appears once every one of its operations is served" do
      waitpoints = Enum.find(Discovery.capabilities(), &(&1.field == "waitpoints_endpoint"))
      base = "https://relay.example.com"

      partial = Discovery.configuration(base, tl(waitpoints.operations))
      refute waitpoints.urn in partial["capabilities"]
      refute Map.has_key?(partial, "waitpoints_endpoint")

      full = Discovery.configuration(base <> "/", waitpoints.operations)
      assert full["capabilities"] == [waitpoints.urn]
      assert full["waitpoints_endpoint"] == base <> "/v1/waitpoints"
      assert full["issuer"] == base
    end

    test "E-81: every capability names contract operations" do
      for capability <- Discovery.capabilities(), id <- capability.operations do
        assert {:ok, _operation} = Contract.operation(id), id
      end
    end
  end

  describe "E-89 product event key set" do
    test "E-89: the key set is served unauthenticated, follows the contract and is empty" do
      {conn, document} = get_document("/.well-known/relay-jwks.json")

      assert conn.status == 200
      Api.assert_contract(conn)
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
      assert document == %{"keys" => []}
    end

    test "E-89: without a product event key the product event capability is not offered" do
      {_conn, document} = get_document("/.well-known/relay-configuration")
      refute "urn:suiss:relay:product_events:1" in document["capabilities"]
    end

    test "E-89: a key of the set is an Ed25519 signing JWK" do
      key = %{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "kid" => "relay-product-1",
        "use" => "sig",
        "x" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }

      schema = Schema.response_schema("getRelayJwks", "200", "application/json")
      root = Schema.build(schema)

      assert :ok == Schema.validate(root, %{"keys" => [key]})
      assert {:error, _} = Schema.validate(root, %{"keys" => [%{key | "kty" => "EC"}]})
    end
  end
end
