defmodule Relay.Operators.Access do
  @moduledoc """
  The port to Access for operators (E-26, E-27, TN-19, TN-21): OpenID Connect authorization code login with PKCE, ID token and operator access token validation, step-up through `acr_values` and `max_age` at an Authenticator Assurance Level compared by rank (E-105), and AuthZEN access evaluation. Relay never authenticates an operator itself and is never an authority: every answer comes from Access, and an Access that cannot be reached fails closed with `auth_step_up_unavailable`.

  The adapter is chosen by `config :relay, Relay.Operators.Access, adapter: module` (`Relay.Operators.Access.Http` in production, `Relay.Operators.Access.Unconfigured` by default). Claims come back normalised: `"sub"`, `"sid"`, `"auth_time"` (a `DateTime`), `"acr"`, `"name"`, `"email"`, `"exp"` (a `DateTime`) and `"step_up_ref"`, the Access record of the authentication that audit records reference (TN-48).
  """

  @aal "http://idmanagement.gov/ns/assurance/aal/"

  @type claims :: %{optional(String.t()) => term()}
  @type authorize_params :: %{
          required(:state) => String.t(),
          required(:nonce) => String.t(),
          required(:code_challenge) => String.t(),
          required(:redirect_uri) => String.t(),
          optional(:acr_values) => String.t(),
          optional(:max_age) => non_neg_integer(),
          optional(:prompt) => String.t()
        }
  @type evaluation :: %{
          required(:subject) => String.t(),
          required(:action) => String.t(),
          required(:resource) => %{type: String.t(), id: String.t()}
        }

  @doc "Builds the Access authorization URL of a login or step-up."
  @callback authorization_url(authorize_params()) :: {:ok, String.t()} | {:error, Relay.Error.t()}

  @doc "Exchanges an authorization code with its PKCE verifier and validates the ID token against the nonce."
  @callback complete(
              code :: String.t(),
              verifier :: String.t(),
              redirect_uri :: String.t(),
              nonce :: String.t()
            ) :: {:ok, claims()} | {:error, Relay.Error.t()}

  @doc "Validates the DPoP-bound Access access token of an operator (the CLI, E-98) with its proof: `aud` Relay's Access `client_id`; `opts` are `:proof`, `:method` and `:url` as in `Relay.Access.verify_access_token/2`."
  @callback verify_access_token(String.t(), keyword()) ::
              {:ok, claims()} | {:error, Relay.Error.t()}

  @doc "Asks the Access decision API (AuthZEN); `:not_offered` when Access offers no decision endpoint."
  @callback evaluate(evaluation()) ::
              {:ok, %{decision: boolean(), ref: String.t() | nil}}
              | :not_offered
              | {:error, Relay.Error.t()}

  # E-26
  @doc "See the `authorization_url/1` callback."
  @spec authorization_url(authorize_params()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def authorization_url(params), do: adapter().authorization_url(params)

  # E-26
  # TN-19
  @doc "See the `complete/4` callback."
  @spec complete(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, claims()} | {:error, Relay.Error.t()}
  def complete(code, verifier, redirect_uri, nonce),
    do: adapter().complete(code, verifier, redirect_uri, nonce)

  # E-98
  @doc "See the `verify_access_token/2` callback."
  @spec verify_access_token(String.t(), keyword()) :: {:ok, claims()} | {:error, Relay.Error.t()}
  def verify_access_token(token, opts), do: adapter().verify_access_token(token, opts)

  # E-27
  # TN-21
  @doc "See the `evaluate/1` callback."
  @spec evaluate(evaluation()) ::
          {:ok, %{decision: boolean(), ref: String.t() | nil}}
          | :not_offered
          | {:error, Relay.Error.t()}
  def evaluate(request), do: adapter().evaluate(request)

  # E-105
  # TN-21
  @doc "The Authenticator Assurance Level a step-up must reach: AAL2, or AAL3 when the installation raises the threshold (`config :relay, Relay.Operators.Access, step_up_aal: 3`); any other value keeps AAL2."
  @spec step_up_aal() :: 2 | 3
  def step_up_aal do
    case Keyword.get(config(), :step_up_aal, 2) do
      3 -> 3
      _default -> 2
    end
  end

  # E-105
  @doc "The Access `acr` value of an Authenticator Assurance Level (the NIST SP 800-63 identifiers Access issues)."
  @spec acr(1..3) :: String.t()
  def acr(aal) when aal in 1..3, do: @aal <> Integer.to_string(aal)

  # E-105
  # TN-21
  @doc "The `acr_values` a step-up asks Access for: the `acr` of the required level."
  @spec step_up_acr() :: String.t()
  def step_up_acr, do: acr(step_up_aal())

  # E-105
  @doc "The Authenticator Assurance Level an `acr` value names, or `nil` when it is not one of Access's values."
  @spec aal(term()) :: 1..3 | nil
  def aal(@aal <> "1"), do: 1
  def aal(@aal <> "2"), do: 2
  def aal(@aal <> "3"), do: 3
  def aal(_acr), do: nil

  # E-105
  # TN-21
  @doc "Returns true if an `acr` reaches the required level by rank: a higher level passes, a lower one and any value that is not an Access level do not."
  @spec acr_satisfied?(term()) :: boolean()
  def acr_satisfied?(acr) when is_binary(acr) do
    required = step_up_aal()

    acr
    |> String.split(" ", trim: true)
    |> Enum.any?(fn value -> (aal(value) || 0) >= required end)
  end

  def acr_satisfied?(_acr), do: false

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: Keyword.get(config(), :adapter, Relay.Operators.Access.Unconfigured)

  @doc "The adapter configuration."
  @spec config() :: keyword()
  def config, do: Application.get_env(:relay, __MODULE__, [])

  @doc "The error of an Access that cannot be reached or answer."
  @spec unavailable(String.t()) :: Relay.Error.t()
  def unavailable(detail \\ "Access cannot be reached"),
    do: Relay.Error.new(:auth_step_up_unavailable, detail)
end
