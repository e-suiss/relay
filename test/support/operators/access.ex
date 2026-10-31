defmodule RelayTest.Operators.Access do
  @moduledoc "Access adapter for operator tests: an authorization code or access token is `code.` or `token.` and the URL-safe Base64 of the JSON claims Access would return (`auth_time` in seconds before now); `unavailable` fails as an unreachable Access. `decide/1` sets the AuthZEN answer of the calling test process: `:not_offered` (the default), `true`, `false` or `:unavailable`."

  use Boundary, top_level?: true, deps: [Relay, Relay.Operators], exports: []

  @behaviour Relay.Operators.Access

  @key :relay_test_authzen

  @doc "A code or token for the claims."
  @spec issue(String.t(), map()) :: String.t()
  def issue(kind, claims) when kind in ["code", "token"],
    do: kind <> "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

  @doc "Sets the AuthZEN answer of this test process."
  @spec decide(:not_offered | boolean() | :unavailable) :: :ok
  def decide(answer) do
    Process.put(@key, answer)
    :ok
  end

  @impl Relay.Operators.Access
  def authorization_url(params) do
    query =
      params |> Map.take([:state, :nonce, :acr_values, :max_age, :prompt]) |> URI.encode_query()

    {:ok, "https://access.test/oauth2/authorize?" <> query}
  end

  @impl Relay.Operators.Access
  def complete("code." <> encoded, _verifier, _redirect_uri, _nonce), do: claims(encoded)
  def complete(_code, _verifier, _redirect_uri, _nonce), do: {:error, unavailable()}

  @impl Relay.Operators.Access
  def verify_access_token("token." <> encoded), do: claims(encoded)
  def verify_access_token("unavailable"), do: {:error, unavailable()}

  def verify_access_token(_token),
    do: {:error, Relay.Error.new(:auth_invalid_token, "unknown test token")}

  @impl Relay.Operators.Access
  def evaluate(_request) do
    case answer() do
      :not_offered -> :not_offered
      :unavailable -> {:error, unavailable()}
      decision when is_boolean(decision) -> {:ok, %{decision: decision, ref: "authzen-1"}}
    end
  end

  defp answer do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, @key)
        nil -> nil
      end
    end)
    |> Kernel.||(:not_offered)
  end

  defp claims(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, normalise(claims)}
    else
      _ -> {:error, Relay.Error.new(:auth_invalid_token, "unknown test code")}
    end
  end

  defp normalise(claims) do
    now = DateTime.to_unix(DateTime.utc_now())

    auth_time =
      case claims["auth_time"] do
        0 -> DateTime.from_unix!(now)
        seconds when is_integer(seconds) -> DateTime.from_unix!(now - seconds)
        _ -> nil
      end

    %{
      "sub" => claims["sub"],
      "sid" => claims["sid"],
      "auth_time" => auth_time,
      "acr" => claims["acr"],
      "name" => claims["name"],
      "email" => claims["email"],
      "step_up_ref" => claims["step_up_ref"],
      "exp" => DateTime.from_unix!(now + 3_600)
    }
  end

  defp unavailable, do: Relay.Error.new(:auth_step_up_unavailable, "Access cannot be reached")
end
