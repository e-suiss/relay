defmodule RelayTest.Api.Verifier do
  @moduledoc "Token verifier for HTTP edge tests: a token is `test.` and the URL-safe Base64 of a JSON principal it was issued for, or of `{\"error\": code}` to make verification fail with that code. Any other token goes to the production verifier, `RelayWeb.Auth.Access`, so tests with tokens of the fake Access (`RelayTest.FakeAccess`) run the real verification."

  use Boundary, top_level?: true, deps: [Relay, RelayWeb], exports: []

  @behaviour RelayWeb.Auth

  alias RelayWeb.Auth.Principal

  @doc "Issues a token for a scope with the given scopes; options `:api_client_id`, `:rate_limit`."
  @spec issue(Relay.Scope.t(), [String.t()], keyword()) :: String.t()
  def issue(%Relay.Scope{} = scope, scopes, opts \\ []) do
    encode(%{
      "tenant_id" => Relay.Scope.tenant_text(scope),
      "environment" => Atom.to_string(scope.environment),
      "scopes" => scopes,
      "api_client_id" => Keyword.get(opts, :api_client_id, "cli_test"),
      "rate_limit" => Keyword.get(opts, :rate_limit)
    })
  end

  @doc "Issues a token whose verification fails with `code`."
  @spec failing(atom()) :: String.t()
  def failing(code), do: encode(%{"error" => Atom.to_string(code)})

  defp encode(claims), do: "test." <> Base.url_encode64(Jason.encode!(claims), padding: false)

  @impl RelayWeb.Auth
  def verify("test." <> encoded, _context) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      principal(claims)
    else
      _ -> invalid()
    end
  end

  def verify(token, context) do
    case String.split(token, ".") do
      [_header, _claims, _signature] -> RelayWeb.Auth.Access.verify(token, context)
      _other -> invalid()
    end
  end

  defp principal(%{"error" => code}),
    do: {:error, Relay.Error.new(String.to_existing_atom(code), "verification failed")}

  defp principal(claims) do
    {:ok, tenant_id} = Ecto.UUID.dump(claims["tenant_id"])

    {:ok,
     %Principal{
       scope: Relay.Scope.new!(tenant_id, claims["environment"]),
       scopes: claims["scopes"],
       api_client_id: claims["api_client_id"],
       rate_limit: claims["rate_limit"]
     }}
  end

  defp invalid, do: {:error, Relay.Error.new(:auth_invalid_token, "unknown test token")}
end
