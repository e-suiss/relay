defmodule EsuissRelay.CredentialsTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Api
  alias EsuissRelay.Client
  alias EsuissRelay.Credentials.AccessClient
  alias EsuissRelay.DpopKey
  alias EsuissRelay.Stub

  defp decode_segment(segment), do: segment |> Base.url_decode64!(padding: false) |> JSON.decode!()

  defp parts(proof) do
    [header, claims, signature] = String.split(proof, ".")
    {decode_segment(header), decode_segment(claims), Base.url_decode64!(signature, padding: false), header <> "." <> claims}
  end

  test "X-29: a DPoP proof is an Ed25519 JWS over htm, htu, iat, jti and ath" do
    key = DpopKey.from_seed(:binary.copy(<<1>>, 32))
    proof = DpopKey.proof(key, "post", "https://relay.test/v1/events?x=1#f", "tok", nil, 1_800_000_000, <<0::128>>)
    {header, claims, signature, input} = parts(proof)

    assert header == %{"typ" => "dpop+jwt", "alg" => "Ed25519", "jwk" => DpopKey.jwk(key)}
    assert claims["htm"] == "POST"
    assert claims["htu"] == "https://relay.test/v1/events"
    assert claims["iat"] == 1_800_000_000
    assert claims["jti"] == Base.url_encode64(<<0::128>>, padding: false)
    assert claims["ath"] == Base.url_encode64(:crypto.hash(:sha256, "tok"), padding: false)
    refute Map.has_key?(claims, "nonce")
    assert :crypto.verify(:eddsa, :none, input, signature, [key.public, :ed25519])
    refute inspect(key) =~ Base.url_encode64(key.private, padding: false)
  end

  test "X-29: Access client credentials are fetched with DPoP, answer a nonce challenge and are cached" do
    nonce = fn _request ->
      {:ok,
       %{
         status: 400,
         headers: [{"dpop-nonce", "n-1"}],
         body: JSON.encode!(%{"error" => "use_dpop_nonce"})
       }}
    end

    token = Stub.json(200, %{"access_token" => "at-1", "token_type" => "DPoP", "expires_in" => 300})
    waitpoint = Stub.json(200, %{"id" => "wp_1", "state" => "open"})

    stub = Stub.start([nonce, token, waitpoint, waitpoint])

    credentials =
      AccessClient.new(
        token_endpoint: "https://access.test/oauth2/token",
        client_id: "cli id",
        client_secret: "s3cret",
        resource: "relay-client",
        scope: "read agents"
      )

    client =
      Client.new(
        base_url: "https://relay.test",
        credentials: credentials,
        transport: {Stub, stub},
        clock: fn -> 1_800_000_000 end
      )

    assert {:ok, _waitpoint} = Api.get_waitpoint(client, "wp_1")
    assert {:ok, _waitpoint} = Api.get_waitpoint(client, "wp_1")

    [first, second, call, again] = Stub.requests(stub)

    assert first.url == "https://access.test/oauth2/token"
    assert first.body == "grant_type=client_credentials&resource=relay-client&scope=read+agents"
    assert Client.header(first.headers, "authorization") == "Basic " <> Base.encode64("cli+id:s3cret")
    {_header, claims, _signature, _input} = parts(Client.header(first.headers, "dpop"))
    refute Map.has_key?(claims, "ath")

    {_header, claims, _signature, _input} = parts(Client.header(second.headers, "dpop"))
    assert claims["nonce"] == "n-1"

    assert Client.header(call.headers, "authorization") == "DPoP at-1"
    assert Client.header(again.headers, "authorization") == "DPoP at-1"
    refute inspect(credentials) =~ "s3cret"
  end

  test "X-29: a token that is not a DPoP token is refused" do
    stub = Stub.start([Stub.json(200, %{"access_token" => "at-1", "token_type" => "Bearer"})])

    client =
      Client.new(
        base_url: "https://relay.test",
        credentials:
          AccessClient.new(
            token_endpoint: "https://access.test/oauth2/token",
            client_id: "c",
            client_secret: "s",
            resource: "r"
          ),
        transport: {Stub, stub}
      )

    assert {:error, %EsuissRelay.AuthenticationError{}} = Api.get_waitpoint(client, "wp_1")
  end
end
