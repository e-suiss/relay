defmodule Relay.Channels.Email.BulkRules do
  @moduledoc """
  The bulk sender rules of the large mailbox providers (CH-37), read from the `email_bulk_sender_rules` data set and checked against a sending domain's checks (`Relay.Channels.Email.DomainCheck`) and its sending figures. The complaint rate is in basis points of mail delivered to the inbox.

  Findings name the provider: errors `bulk_spf`, `bulk_dkim`, `bulk_dmarc_policy`, `bulk_dmarc_alignment`, `bulk_one_click`, `bulk_complaint_rate` and `bulk_unsubscribe_delay`; the warning `bulk_complaint_target`.
  """

  alias Relay.Channels.Email.DomainCheck

  @policies %{"none" => 0, "quarantine" => 1, "reject" => 2}

  @type finding :: %{provider: String.t(), severity: :error | :warning, code: atom()}
  @type figures :: %{
          required(:one_click_unsubscribe) => boolean(),
          required(:unsubscribe_within_days) => non_neg_integer(),
          optional(:complaint_bp) => %{String.t() => non_neg_integer()}
        }

  # CH-37
  @doc "The provider row covering a recipient domain, or `nil`."
  @spec provider(map(), String.t()) :: map() | nil
  def provider(%{"providers" => providers}, recipient_domain) do
    domain = String.downcase(recipient_domain, :ascii)
    Enum.find(providers, &(domain in &1["domains"]))
  end

  # CH-37
  @doc "Checks a sending domain against every provider's rules; `figures` carries whether one-click unsubscribe is sent, the days within which an unsubscribe is applied and the complaint rate per provider."
  @spec evaluate(map(), DomainCheck.t(), figures()) :: [finding()]
  def evaluate(%{"providers" => providers}, check, figures) do
    Enum.flat_map(providers, &provider_findings(&1, check, figures))
  end

  defp provider_findings(%{"provider" => name, "requirements" => rules}, check, figures) do
    errors = for %{severity: :error, code: code} <- check.findings, do: Atom.to_string(code)
    spf_ok = not Enum.any?(errors, &String.starts_with?(&1, "spf_"))
    dkim_ok = not Enum.any?(errors, &String.starts_with?(&1, "dkim_"))
    unaligned = Enum.any?(check.findings, &(&1.code == :return_path_unaligned))
    complaint = figures |> Map.get(:complaint_bp, %{}) |> Map.get(name, 0)
    max = rules["complaint_rate_max_bp"]
    one_click = figures.one_click_unsubscribe
    delay = figures.unsubscribe_within_days
    near = complaint >= rules["complaint_rate_target_bp"] and complaint < max

    [
      {rules["spf"] and not spf_ok, :error, :bulk_spf},
      {rules["dkim"] and not dkim_ok, :error, :bulk_dkim},
      {not policy_at_least?(check.dmarc, rules["dmarc_min_policy"]), :error, :bulk_dmarc_policy},
      {rules["dmarc_alignment"] and not dkim_ok and unaligned, :error, :bulk_dmarc_alignment},
      {rules["one_click_unsubscribe"] and not one_click, :error, :bulk_one_click},
      {complaint >= max, :error, :bulk_complaint_rate},
      {near, :warning, :bulk_complaint_target},
      {delay > rules["unsubscribe_within_days"], :error, :bulk_unsubscribe_delay}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {true, level, code} -> %{provider: name, severity: level, code: code} end)
  end

  defp policy_at_least?(nil, _minimum), do: false

  defp policy_at_least?(%{policy: policy}, minimum),
    do: Map.get(@policies, policy || "none", 0) >= Map.fetch!(@policies, minimum)
end
