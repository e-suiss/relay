defmodule Relay.Operators.Access.Http do
  @moduledoc """
  The Access adapter that talks to the endpoints Access publishes in its discovery document, through `Req`. Configuration (`config :relay, Relay.Operators.Access, ...`): `client_id`, `client_secret` (a zero-arity `{module, function, args}` callback returning the secret, called only when the secret is used), `operator_audience` (the `aud` of an operator access token) and `discovery`.

  `issuer` defaults to the issuer of the Access link (`config :relay, Relay.Access, issuer: ...`). `discovery` is a `{module, function, args}` callback returning `{:ok, map}` with the string keys of an OpenID Provider metadata document: `"issuer"`, `"authorization_endpoint"`, `"token_endpoint"`, `"jwks"` (the JSON Web Key Set itself, `%{"keys" => [...]}`) and, when Access offers AuthZEN, `"access_evaluation_endpoint"`. The Access link's discovery cache plugs in here; without one the adapter reads `<issuer>/.well-known/openid-configuration` and its `jwks_uri` on every call (`discover/0`, with `issuer` configured). Any failure to reach Access is `auth_step_up_unavailable`.

  Tokens are JWS compact serialisations signed with `EdDSA`, `ES256` or `PS256`; any other algorithm, an unsigned token, a wrong `iss` or `aud`, an expired token or a token not yet valid (60 seconds of clock skew) is refused.
  """

  @behaviour Relay.Operators.Access

  alias Relay.Operators.Access

  @timeout_ms 5_000
  @skew_s 60
  @algorithms ["EdDSA", "ES256", "PS256"]

  @impl Access
  def authorization_url(params) do
    with {:ok, discovery} <- discovery() do
      query =
        [
          response_type: "code",
          client_id: client_id(),
          redirect_uri: params.redirect_uri,
          scope: "openid profile email",
          state: params.state,
          nonce: params.nonce,
          code_challenge: params.code_challenge,
          code_challenge_method: "S256"
        ] ++ optional(params, [:acr_values, :max_age, :prompt])

      {:ok, discovery["authorization_endpoint"] <> "?" <> URI.encode_query(query)}
    end
  end

  @impl Access
  def complete(code, verifier, redirect_uri, nonce) do
    form = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: verifier
    ]

    with {:ok, discovery} <- discovery(),
         {:ok, %{"id_token" => id_token}} <- token(discovery, form),
         {:ok, claims} <- verify(id_token, discovery, client_id()) do
      if Map.get(claims, "nonce") == nonce,
        do: {:ok, normalise(claims)},
        else: {:error, invalid("the ID token nonce does not match")}
    else
      {:ok, _other} -> {:error, invalid("Access returned no ID token")}
      {:error, error} -> {:error, error}
    end
  end

  @impl Access
  def verify_access_token(token) do
    audience = Keyword.get(Access.config(), :operator_audience, "relay-operator-api")

    with {:ok, discovery} <- discovery(),
         {:ok, claims} <- verify(token, discovery, audience),
         do: {:ok, normalise(claims)}
  end

  @impl Access
  def evaluate(request) do
    with {:ok, discovery} <- discovery() do
      case discovery["access_evaluation_endpoint"] do
        endpoint when is_binary(endpoint) -> evaluate_at(discovery, endpoint, request)
        _ -> :not_offered
      end
    end
  end

  defp evaluate_at(discovery, endpoint, request) do
    body = %{
      "subject" => %{"type" => "user", "id" => request.subject},
      "action" => %{"name" => request.action},
      "resource" => %{"type" => request.resource.type, "id" => request.resource.id}
    }

    with {:ok, %{"access_token" => bearer}} <-
           token(discovery, grant_type: "client_credentials"),
         {:ok, %{status: 200, body: %{"decision" => decision} = answer}}
         when is_boolean(decision) <-
           send_request(
             method: :post,
             url: endpoint,
             json: body,
             headers: [{"authorization", "Bearer " <> bearer}]
           ) do
      ref = get_in(answer, ["context", "decision_ref"]) || get_in(answer, ["context", "id"])
      {:ok, %{decision: decision, ref: if(is_binary(ref), do: ref)}}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _other -> {:error, Access.unavailable("Access gave no decision")}
    end
  end

  # E-78
  @doc "Reads the discovery document of the configured `issuer` and its JSON Web Key Set."
  @spec discover() :: {:ok, map()} | {:error, Relay.Error.t()}
  def discover do
    issuer = Keyword.get(Access.config(), :issuer) || Relay.Access.issuer()

    with true <- is_binary(issuer) || {:error, Access.unavailable("no Access issuer")},
         url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration",
         {:ok, %{status: 200, body: %{"jwks_uri" => jwks_uri} = document}} <-
           send_request(method: :get, url: url),
         {:ok, %{status: 200, body: %{"keys" => keys} = jwks}} when is_list(keys) <-
           send_request(method: :get, url: jwks_uri),
         true <- document["issuer"] == issuer || {:error, invalid("the issuer does not match")} do
      {:ok, Map.put(document, "jwks", jwks)}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _other -> {:error, Access.unavailable("the Access discovery document is unavailable")}
    end
  end

  defp discovery do
    {module, function, args} =
      Keyword.get(Access.config(), :discovery, {__MODULE__, :discover, []})

    case apply(module, function, args) do
      {:ok, %{"authorization_endpoint" => _, "token_endpoint" => _, "jwks" => _} = d} -> {:ok, d}
      {:ok, _incomplete} -> {:error, Access.unavailable("the discovery document is incomplete")}
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  defp token(discovery, form) do
    case send_request(
           method: :post,
           url: discovery["token_endpoint"],
           form: form,
           auth: {:basic, client_id() <> ":" <> client_secret()}
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} when status in 400..499 -> {:error, invalid("Access refused")}
      {:ok, _response} -> {:error, Access.unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  defp send_request(options) do
    req =
      Req.new(
        [retry: false, redirect: false, receive_timeout: @timeout_ms] ++
          [connect_options: [timeout: @timeout_ms]] ++ options
      )

    :ok = Relay.NetworkGuard.check!(:http)

    case Req.request(req) do
      {:ok, response} -> {:ok, response}
      {:error, _exception} -> {:error, Access.unavailable()}
    end
  end

  # E-26
  @doc "Verifies a JWS compact token with the key set of `discovery` and checks `iss`, `aud`, `exp` and `nbf`; returns its claims."
  @spec verify(String.t(), map(), String.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def verify(token, discovery, audience) when is_binary(token) do
    with [header64, payload64, signature64] <- String.split(token, "."),
         {:ok, header} <- decode_json(header64),
         {:ok, claims} <- decode_json(payload64),
         {:ok, signature} <- Base.url_decode64(signature64, padding: false),
         %{"alg" => alg} when alg in @algorithms <- header,
         {:ok, key} <- key(discovery["jwks"], header),
         true <- signed?(alg, header64 <> "." <> payload64, signature, key),
         :ok <- registered(claims, discovery["issuer"], audience) do
      {:ok, claims}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _other -> {:error, invalid("the token is not valid")}
    end
  end

  def verify(_token, _discovery, _audience), do: {:error, invalid("the token is not valid")}

  defp decode_json(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _other -> :error
    end
  end

  defp key(%{"keys" => keys}, header) when is_list(keys) do
    case Enum.filter(keys, &(&1["kid"] == header["kid"] and usable?(&1, header["alg"]))) do
      [key | _] -> {:ok, key}
      [] -> :error
    end
  end

  defp key(_jwks, _header), do: :error

  defp usable?(%{"kty" => "OKP", "crv" => "Ed25519"}, "EdDSA"), do: true
  defp usable?(%{"kty" => "EC", "crv" => "P-256"}, "ES256"), do: true
  defp usable?(%{"kty" => "RSA"}, "PS256"), do: true
  defp usable?(_key, _alg), do: false

  defp signed?("EdDSA", input, signature, %{"x" => x}) do
    with {:ok, public} <- Base.url_decode64(x, padding: false),
         do: :crypto.verify(:eddsa, :none, input, signature, [public, :ed25519])
  end

  defp signed?("ES256", input, <<r::256, s::256>>, %{"x" => x, "y" => y}) do
    with {:ok, x} <- Base.url_decode64(x, padding: false),
         {:ok, y} <- Base.url_decode64(y, padding: false) do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      :crypto.verify(:ecdsa, :sha256, input, der, [<<4, x::binary, y::binary>>, :secp256r1])
    end
  end

  defp signed?("PS256", input, signature, %{"n" => n, "e" => e}) do
    with {:ok, n} <- Base.url_decode64(n, padding: false),
         {:ok, e} <- Base.url_decode64(e, padding: false) do
      :crypto.verify(:rsa, :sha256, input, signature, [e, n],
        rsa_padding: :rsa_pkcs1_pss_padding,
        rsa_pss_saltlen: 32,
        rsa_mgf1_md: :sha256
      )
    end
  end

  defp signed?(_alg, _input, _signature, _key), do: false

  defp registered(claims, issuer, audience) do
    now = DateTime.to_unix(Relay.Clock.utc_now())
    audiences = List.wrap(claims["aud"])

    cond do
      claims["iss"] != issuer -> {:error, invalid("the token issuer does not match")}
      audience not in audiences -> {:error, invalid("the token audience does not match")}
      not is_integer(claims["exp"]) or claims["exp"] + @skew_s <= now -> {:error, expired()}
      is_integer(claims["nbf"]) and claims["nbf"] - @skew_s > now -> {:error, invalid("early")}
      not is_binary(claims["sub"]) -> {:error, invalid("the token has no subject")}
      true -> :ok
    end
  end

  defp normalise(claims) do
    auth_time =
      case claims["auth_time"] do
        seconds when is_integer(seconds) -> DateTime.from_unix!(seconds)
        _ -> nil
      end

    %{
      "sub" => claims["sub"],
      "sid" => claims["sid"],
      "auth_time" => auth_time,
      "acr" => claims["acr"],
      "name" => claims["name"],
      "email" => claims["email"],
      "step_up_ref" => claims["step_up_ref"] || claims["jti"],
      "exp" => if(is_integer(claims["exp"]), do: DateTime.from_unix!(claims["exp"]))
    }
  end

  defp optional(params, keys) do
    for key <- keys, value = Map.get(params, key), value != nil, do: {key, value}
  end

  defp client_id, do: Keyword.get(Access.config(), :client_id, "")

  defp client_secret do
    case Keyword.get(Access.config(), :client_secret) do
      {module, function, args} ->
        module |> apply(function, args) |> Relay.Redacted.wrap() |> Relay.Redacted.expose()

      _ ->
        ""
    end
  end

  defp invalid(detail), do: Relay.Error.new(:auth_invalid_token, detail)
  defp expired, do: Relay.Error.new(:auth_expired_token, "the token has expired")
end
