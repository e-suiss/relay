defmodule Relay.Compliance do
  @moduledoc """
  Compliance rules that do not depend on a channel: the compliance table, refusal notices, the keywords of an inbound SMS and the one-click unsubscribe token (PC-40, PC-35, PC-37, PC-38, PC-39).

  The compliance table (PC-40, MD-17) says what consent a delivery needs for its country, channel, message class and legal recipient type, with the platform rows, the derived `marketing` default, the legal send window and the scope of a revocation. These rules are pure functions of the content of the `compliance_table` and `compliance_settings` data sets; nothing is read or written. The country of a recipient comes from the profile country and from the country calling code of the phone number; when they differ, the more restrictive row decides. A recipient without either is read with the country of the tenant's region.

  A refusal is described here (`Relay.Compliance.Refusal`) and applied by the module configured as `config :relay, Relay.Compliance, refusals: Module`, which implements this behaviour; `Relay.Compliance.Refusals` on a running node. Once a refusal notice is applied in Relay it is handed to the refusal sink (`Relay.Compliance.RefusalSink`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: [Refusal, RefusalSink, IysChannel]

  alias Relay.Compliance.Refusal
  alias Relay.Compliance.Settings
  alias Relay.Compliance.SmsKeyword
  alias Relay.Compliance.Table
  alias Relay.Compliance.UnsubscribeToken
  alias Relay.Scope

  @type applied :: %{result: :applied | :reapplied | :exists, refusal_id: Relay.Id.t()}

  @doc "Applies a described refusal in `scope` at once and in one transaction."
  @callback apply_refusal(Scope.t(), Refusal.t()) :: {:ok, applied()} | {:error, Relay.Error.t()}

  # PC-38
  # PC-39
  # INV-18
  @doc """
  Records a refusal of a recipient and applies it at once. `attrs` carries `:recipient_id`, `:channel`, `:source` (`unsubscribe_page`, `sms_keyword`, `complaint`, `whatsapp`, `iys`, or the category exits `rfc8058`, `unsubscribe_link` and `mailto`), `:ref` (what identifies the request, so a repeat changes nothing) and optionally `:scope` (`category`, `all_marketing` or `all_channel`; the default of the source otherwise), `:category` (with the `category` scope), `:brand_subtenant_id`, `:occurred_at`, `:evidence` (`:ip` and `:user_agent`, redacted), `:covers` (the other channels an `all_channel` refusal reaches, PC-61), `:provider_account_id` (the account an SMS refusal arrived through) and `:actor_ref`. Reaches the key store, so it never runs inside a transaction.
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

  # PC-37
  @doc "The keyword set and the canonical keyword of an inbound SMS, or `:none`; see `Relay.Compliance.SmsKeyword.classify/1`."
  @spec sms_keyword(term()) :: {SmsKeyword.set(), String.t()} | :none
  defdelegate sms_keyword(text), to: SmsKeyword, as: :classify

  # PC-39
  # PC-61
  @doc "The scope of a refusal keyword and the channels it covers; see `Relay.Compliance.SmsKeyword.revocation/2`."
  @spec sms_revocation(SmsKeyword.set(), [SmsKeyword.revocation() | nil]) ::
          SmsKeyword.revocation()
  defdelegate sms_revocation(set, scopes), to: SmsKeyword, as: :revocation

  # PC-37
  @doc "The text of a keyword reply; see `Relay.Compliance.SmsKeyword.reply/3`."
  @spec sms_reply(SmsKeyword.reply(), String.t() | nil, String.t() | nil) :: String.t()
  defdelegate sms_reply(kind, locale, brand), to: SmsKeyword, as: :reply

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

  @regions %{"tr" => "TR", "eu" => "EU", "us" => "US"}

  @type table :: Table.content()
  @type query :: Table.query()
  @type resolution :: Table.resolution()

  # PC-44
  @doc "The number and content of the `compliance_table` version bundled with the release."
  @spec bundled_table() :: {pos_integer(), table()}
  def bundled_table, do: Table.bundled()

  # PC-40
  # PC-44
  @doc "Checks the consistency rules of a `compliance_table` version; see `Relay.Compliance.Table.validate/1`."
  @spec validate_table(map()) :: :ok | {:error, Relay.Error.t()}
  def validate_table(content), do: Table.validate(content)

  # PC-40
  @doc "Checks the consistency rules of a `compliance_settings` version; see `Relay.Compliance.Settings.validate/1`."
  @spec validate_settings(map()) :: :ok | {:error, Relay.Error.t()}
  def validate_settings(content), do: Settings.validate(content)

  # INV-17
  @doc "Checks a tenant's refusals; see `Relay.Compliance.Settings.check/1`."
  @spec check_refusals([map()]) :: [{non_neg_integer(), String.t(), String.t()}]
  def check_refusals(rows), do: Settings.check(rows)

  # INV-17
  @doc "The refusals in force from the installation's and the tenant's `compliance_settings` content; see `Relay.Compliance.Settings.merge/2`."
  @spec refusals(map() | nil, map() | nil) :: Settings.refusals()
  def refusals(installation, tenant), do: Settings.merge(installation, tenant)

  # PC-40
  @doc "The country a region's tenants are read with when a recipient has no country: the region's own row key."
  @spec region_country(String.t()) :: String.t()
  def region_country(region), do: Map.fetch!(@regions, region)

  # PC-40
  # PC-47
  @doc "The countries a recipient may be in, from the phone number's country calling code and the profile country; see `Relay.Compliance.Table.candidates/3`."
  @spec candidates(table(), String.t() | nil, String.t() | nil) :: [String.t()]
  def candidates(table, calling_code, profile_country),
    do: Table.candidates(table, calling_code, profile_country)

  # PC-40
  # PC-41
  # PC-54
  # INV-17
  @doc "Resolves what a delivery needs from the table and the refusals in force; see `Relay.Compliance.Table.resolve/3`."
  @spec resolve(table(), Settings.refusals(), query()) :: resolution()
  def resolve(table, refusals, query), do: Table.resolve(table, refusals, query)

  # PC-39
  # PC-61
  @doc "The scope of a revocation received in `country` on `channel`; see `Relay.Compliance.Table.revocation_scope/3`."
  @spec revocation_scope(table(), String.t(), String.t()) ::
          %{scope: String.t(), channels: [String.t()]} | nil
  def revocation_scope(table, country, channel),
    do: Table.revocation_scope(table, country, channel)

  # TP-33
  @doc "The footer fields a commercial message to `country` on `channel` must carry; see `Relay.Compliance.Table.footer/3`."
  @spec footer(table(), String.t(), String.t()) :: [String.t()]
  def footer(table, country, channel), do: Table.footer(table, country, channel)
end
