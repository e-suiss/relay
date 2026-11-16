defmodule Relay.Webhooks.Destination.AwsSigV4Test do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AwsSigV4

  @suite_time ~U[2015-08-30 12:36:00Z]
  @suite_scope %{region: "us-east-1", service: "service"}
  @suite_url "https://example.amazonaws.com/"
  @authorization ~r/\AAWS4-HMAC-SHA256 Credential=(\S+), SignedHeaders=(\S+), Signature=(\S+)\z/

  defp suite_credentials do
    secret = Enum.join(["wJalrXUtnFEMI", "K7MDENG+bPxRfiCYEXAMPLEKEY"], "/")
    %{access_key_id: "AKIDEXAMPLE", secret_access_key: Redacted.wrap(secret)}
  end

  defp suite(method, url, headers, body) do
    request = %{method: method, url: url, headers: headers, body: body}
    {:ok, signed} = AwsSigV4.sign(request, suite_credentials(), @suite_scope, @suite_time)
    signed
  end

  defp authorization(headers) do
    {"authorization", value} = List.keyfind(headers, "authorization", 0)
    [_all, credential, signed_headers, signature] = Regex.run(@authorization, value)
    %{credential: credential, signed_headers: signed_headers, signature: signature}
  end

  describe "WH-17 the published Signature Version 4 test suite" do
    test "WH-17: get-vanilla" do
      headers = suite("GET", @suite_url, [], "")
      authorization = authorization(headers)

      assert {"x-amz-date", "20150830T123600Z"} in headers
      assert authorization.credential == "AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"
      assert authorization.signed_headers == "host;x-amz-date"

      assert authorization.signature ==
               "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    end

    test "WH-17: post-vanilla" do
      authorization = authorization(suite("POST", @suite_url, [], ""))

      assert authorization.signature ==
               "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
    end

    test "WH-17: get-vanilla-query-order-key-case sorts the query" do
      url = @suite_url <> "?Param2=value2&Param1=value1"
      authorization = authorization(suite("GET", url, [], ""))

      assert authorization.signature ==
               "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"
    end

    test "WH-17: get-unreserved keeps the unreserved characters of the path" do
      url = @suite_url <> "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
      authorization = authorization(suite("GET", url, [], ""))

      assert authorization.signature ==
               "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f"
    end

    test "WH-17: post-x-www-form-urlencoded signs the content type and the body" do
      headers = [{"Content-Type", "application/x-www-form-urlencoded"}]
      authorization = authorization(suite("POST", @suite_url, headers, "Param1=value1"))

      assert authorization.signed_headers == "content-type;host;x-amz-date"

      assert authorization.signature ==
               "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"
    end
  end

  describe "WH-17 the published S3 example" do
    test "WH-17: PutObject signs the path as written and the payload digest" do
      secret = Enum.join(["wJalrXUtnFEMI", "K7MDENG", "bPxRfiCYEXAMPLEKEY"], "/")
      key_id = Enum.join(["AKIA", "IOSFODNN7EXAMPLE"])
      credentials = %{access_key_id: key_id, secret_access_key: Redacted.wrap(secret)}

      request = %{
        method: "PUT",
        url: "https://examplebucket.s3.amazonaws.com/test%24file.text",
        headers: [
          {"date", "Fri, 24 May 2013 00:00:00 GMT"},
          {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
        ],
        body: "Welcome to Amazon S3."
      }

      scope = %{region: "us-east-1", service: "s3"}
      {:ok, headers} = AwsSigV4.sign(request, credentials, scope, ~U[2013-05-24 00:00:00Z])
      authorization = authorization(headers)
      digest = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

      assert {"x-amz-content-sha256", digest} in headers
      assert authorization.credential == key_id <> "/20130524/us-east-1/s3/aws4_request"

      assert authorization.signed_headers ==
               "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"

      assert authorization.signature ==
               "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    end
  end

  describe "WH-17 temporary credentials and ports" do
    test "WH-17: the session token of temporary credentials is sent and signed" do
      credentials = Map.put(suite_credentials(), :session_token, Redacted.wrap("session-1"))
      request = %{method: "GET", url: @suite_url, headers: [], body: ""}

      {:ok, headers} = AwsSigV4.sign(request, credentials, @suite_scope, @suite_time)
      authorization = authorization(headers)

      assert {"x-amz-security-token", "session-1"} in headers
      assert authorization.signed_headers == "host;x-amz-date;x-amz-security-token"
      refute authorization.signature == authorization(suite("GET", @suite_url, [], "")).signature
    end

    test "WH-17: a port other than 443 is part of the signed host" do
      plain = authorization(suite("GET", @suite_url, [], ""))
      ported = authorization(suite("GET", "https://example.amazonaws.com:9000/", [], ""))
      explicit = authorization(suite("GET", "https://example.amazonaws.com:443/", [], ""))

      refute plain.signature == ported.signature
      assert plain.signature == explicit.signature
    end

    test "WH-17: a URL that cannot be sent is not signed" do
      request = %{method: "GET", url: "https://exa mple/", headers: [], body: ""}
      result = AwsSigV4.sign(request, suite_credentials(), @suite_scope, @suite_time)

      assert result == {:error, :invalid_url}
    end
  end

  describe "WH-19 the secret access key" do
    test "WH-19: the secret is in nothing the signer returns" do
      headers = suite("GET", @suite_url, [], "")

      refute inspect(headers) =~ "bPxRfiCYEXAMPLEKEY"
      refute inspect(suite_credentials()) =~ "bPxRfiCYEXAMPLEKEY"
    end
  end
end
