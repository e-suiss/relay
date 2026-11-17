defmodule RelayWeb.Links.Unsubscribe do
  @moduledoc """
  The link handler of a running installation (`config :relay, RelayWeb.Links, handler: RelayWeb.Links.Unsubscribe`): Relay's own links are the one-click unsubscribe links of bulk e-mail (PC-35, PC-36). A link takes its recipient out of the category of its message as a preference; the refusal its page offers is a refusal notice for every marketing e-mail of the brand (`Relay.Compliance.Refusals`).
  """

  @behaviour RelayWeb.Links

  alias Relay.Compliance.Refusals

  # PC-35
  # PC-36
  @impl RelayWeb.Links
  def describe(token) do
    case Refusals.describe_link(token) do
      {:ok, link} -> {:ok, %{kind: :unsubscribe, locale: link.locale, state: link.state}}
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-35
  # INV-18
  @impl RelayWeb.Links
  def apply_link(token, evidence), do: Refusals.apply_link(token, evidence)

  # PC-36
  # PC-38
  @impl RelayWeb.Links
  def refuse(token, evidence), do: Refusals.refuse_link(token, evidence)
end
