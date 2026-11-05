defmodule Relay.Channels.Push.FcmAuthTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Fcm.Auth
  alias Relay.Channels.Push.Jwt

  @now 1_793_836_800
  @audience "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/k"

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    signer = fn :rs256, "fcm-sa", msg -> {:ok, :public_key.sign(msg, :sha256, private)} end

    sa = %{
      kind: :service_account,
      project_id: "relay-test",
      client_email: "push@relay-test.iam.gserviceaccount.com",
      private_key_id: "kid-1",
      label: "fcm-sa"
    }

    %{public: public, signer: signer, sa: sa}
  end

  defp form(body), do: URI.decode_query(body)

  defp http(responses) do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(parent, {:request, request})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end

  describe "TN-30 service account assertion" do
    test "TN-30: the RS256 assertion is signed through the key store and verifies", ctx do
      assert {:ok, assertion} = Auth.assertion(ctx.sa, @now, ctx.signer)
      [h, c, s] = String.split(assertion, ".")
      {:ok, signature} = Jwt.decode64(s)
      assert :public_key.verify(h <> "." <> c, :sha256, signature, ctx.public)

      {:ok, header} = Jwt.decode64(h)
      assert Jason.decode!(header) == %{"alg" => "RS256", "typ" => "JWT", "kid" => "kid-1"}

      assert Jwt.peek_claims(assertion) ==
               {:ok,
                %{
                  "iss" => "push@relay-test.iam.gserviceaccount.com",
                  "scope" => "https://www.googleapis.com/auth/firebase.messaging",
                  "aud" => "https://oauth2.googleapis.com/token",
                  "iat" => @now,
                  "exp" => @now + 3600
                }}
    end

    test "TN-30: the token request is the JWT bearer grant", ctx do
      request = Auth.token_request(ctx.sa, "a.b.c")
      assert request.url == "https://oauth2.googleapis.com/token"
      assert {"content-type", "application/x-www-form-urlencoded"} in request.headers

      assert form(request.body) == %{
               "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
               "assertion" => "a.b.c"
             }
    end

    test "TN-30: the token is cached per project for its lifetime, less a minute", ctx do
      body = Jason.encode!(%{"access_token" => "ya29.one", "expires_in" => 3599})
      again = Jason.encode!(%{"access_token" => "ya29.two", "expires_in" => 3599})
      http = http([{:ok, %{status: 200, body: body}}, {:ok, %{status: 200, body: again}}])
      opts = [http: http, signer: ctx.signer]

      assert {:ok, token, cache} = Auth.access_token(ctx.sa, %{}, @now, opts)
      assert Relay.Redacted.expose(token) == "ya29.one"
      assert inspect(token) =~ "redacted"
      assert_received {:request, _first}

      assert {:ok, ^token, ^cache} = Auth.access_token(ctx.sa, cache, @now + 3538, opts)
      refute_received {:request, _cached}

      assert {:ok, renewed, cache} = Auth.access_token(ctx.sa, cache, @now + 3539, opts)
      assert Relay.Redacted.expose(renewed) == "ya29.two"
      assert_received {:request, _second}
      assert Map.keys(cache) == ["relay-test"]
    end

    test "TN-30: a refused or malformed token response is an error", ctx do
      http = http([{:ok, %{status: 400, body: "{}"}}, {:ok, %{status: 200, body: "{}"}}])
      opts = [http: http, signer: ctx.signer]

      assert {:error, %{code: :fcm_auth_failed, details: %{status: 400}}} =
               Auth.access_token(ctx.sa, %{}, @now, opts)

      assert {:error, %{code: :fcm_auth_failed}} = Auth.access_token(ctx.sa, %{}, @now, opts)

      unreachable = fn _request -> {:error, :timeout} end

      assert {:error, %{code: :fcm_auth_unavailable}} =
               Auth.access_token(ctx.sa, %{}, @now, http: unreachable, signer: ctx.signer)
    end
  end

  describe "TN-30 workload identity federation" do
    setup do
      %{
        wif: %{
          kind: :workload_identity,
          project_id: "relay-test",
          audience: @audience,
          subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
          service_account: "push@relay-test.iam.gserviceaccount.com"
        }
      }
    end

    test "TN-30: the subject token is exchanged and the service account impersonated", ctx do
      sts = Jason.encode!(%{"access_token" => "federated", "expires_in" => 3600})
      expiry = "2026-11-05T01:00:00Z"
      iam = Jason.encode!(%{"accessToken" => "ya29.sa", "expireTime" => expiry})
      http = http([{:ok, %{status: 200, body: sts}}, {:ok, %{status: 200, body: iam}}])
      opts = [http: http, subject_token: fn -> {:ok, "workload.jwt"} end]

      assert {:ok, token, cache} = Auth.access_token(ctx.wif, %{}, @now, opts)
      assert Relay.Redacted.expose(token) == "ya29.sa"
      assert cache["relay-test"].expires_at == 1_793_840_400

      assert_received {:request, %{url: "https://sts.googleapis.com/v1/token", body: body}}

      assert %{
               "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
               "subject_token" => "workload.jwt",
               "scope" => "https://www.googleapis.com/auth/cloud-platform"
             } = form(body)

      assert_received {:request, %{url: url, headers: headers, body: iam_body}}
      assert url =~ ":generateAccessToken"
      assert {"authorization", "Bearer federated"} in headers

      assert Jason.decode!(iam_body) == %{
               "scope" => ["https://www.googleapis.com/auth/firebase.messaging"],
               "lifetime" => "3600s"
             }
    end

    test "TN-30: without a service account the federated token is used directly", ctx do
      wif = Map.delete(ctx.wif, :service_account)
      sts = Jason.encode!(%{"access_token" => "federated", "expires_in" => 3600})
      opts = [http: http([{:ok, %{status: 200, body: sts}}]), subject_token: fn -> {:ok, "w"} end]

      assert {:ok, token, _cache} = Auth.access_token(wif, %{}, @now, opts)
      assert Relay.Redacted.expose(token) == "federated"
      assert_received {:request, %{body: body}}
      assert form(body)["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    end

    test "TN-30: a missing workload token is an error", ctx do
      opts = [http: http([]), subject_token: fn -> {:error, :none} end]
      assert {:error, %{code: :fcm_auth_failed}} = Auth.access_token(ctx.wif, %{}, @now, opts)
      refute_received {:request, _request}
    end
  end
end
