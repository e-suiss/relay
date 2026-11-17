defmodule Relay.Compliance do
  @moduledoc """
  Compliance rules that do not depend on a channel: refusal notices and the one-click unsubscribe token (PC-35, PC-38, PC-39).

  A refusal is described here (`Relay.Compliance.Refusal`) and applied by the module configured as `config :relay, Relay.Compliance, refusals: Module`, which implements this behaviour; `Relay.Compliance.Refusals` on a running node. Once a refusal notice is applied in Relay it is handed to the refusal sink (`Relay.Compliance.RefusalSink`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: [Refusal, RefusalSink]

  alias Relay.Compliance.Refusal
  alias Relay.Compliance.UnsubscribeToken
  alias Relay.Scope

  @type applied :: %{result: :applied | :reapplied | :exists, refusal_id: Relay.Id.t()}

  @doc "Applies a described refusal in `scope` at once and in one transaction."
  @callback apply_refusal(Scope.t(), Refusal.t()) :: {:ok, applied()} | {:error, Relay.Error.t()}

  # PC-38
  # PC-39
  # INV-18
  @doc """
  Records a refusal of a recipient and applies it at once. `attrs` carries `:recipient_id`, `:channel`, `:source` (`unsubscribe_page`, `sms_keyword`, `complaint`, `whatsapp`, `iys`, or the category exits `rfc8058`, `unsubscribe_link` and `mailto`), `:ref` (what identifies the request, so a repeat changes nothing) and optionally `:scope` (`category`, `all_marketing` or `all_channel`; the default of the source otherwise), `:category` (with the `category` scope), `:brand_subtenant_id`, `:occurred_at`, `:evidence` (`:ip` and `:user_agent`, redacted), `:address` (redacted) and `:actor_ref`. Reaches the key store, so it never runs inside a transaction.
  """
  @spec refuse(Scope.t(), map()) :: {:ok, applied()} | {:error, Relay.Error.t()}
  def refuse(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, refusal} <- Refusal.new(attrs) do
      case config(:refusals, nil) do
        nil -> {:error, Relay.Error.new(:service_unavailable, "refusals are not applied here")}
        module -> module.apply_refusal(scope, refusal)
      end
    end
  end

  # PC-39
  @doc "The scope a refusal of `source` has when none is given; `nil` for an unknown source."
  @spec default_scope(String.t()) :: String.t() | nil
  defdelegate default_scope(source), to: Refusal

  # PC-35
  # TN-35
  @doc "Signs a one-click unsubscribe token; see `Relay.Compliance.UnsubscribeToken.issue/1`."
  @spec issue_unsubscribe_token(UnsubscribeToken.claims()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  defdelegate issue_unsubscribe_token(claims), to: UnsubscribeToken, as: :issue

  # PC-35
  # TN-35
  @doc "Verifies a one-click unsubscribe token; see `Relay.Compliance.UnsubscribeToken.verify/1`."
  @spec verify_unsubscribe_token(term()) ::
          {:ok, UnsubscribeToken.claims()} | {:error, :invalid | :unavailable}
  defdelegate verify_unsubscribe_token(token), to: UnsubscribeToken, as: :verify

  @doc "The configured value of `key`, or `default`."
  @spec config(atom(), term()) :: term()
  def config(key, default),
    do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
