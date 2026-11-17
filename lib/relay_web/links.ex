defmodule RelayWeb.Links do
  @moduledoc """
  The owner of Relay's own one-time links (CH-76): one-click unsubscribe, a preference change and Relay's own address verification. A link opens Relay's confirmation page on its public root; `GET` only shows the page and never changes anything, so a security scanner that opens the link does not consume it, and the change is made by the page's `POST` (CH-44). The RFC 8058 `List-Unsubscribe-Post` request is applied directly, without a page (PC-35). The page of an applied unsubscribe link says so and offers two ways on: the recipient's preferences, when `config :relay, RelayWeb.Links, preferences_url: "https://..."` names where they are managed, and a refusal of every commercial e-mail of the brand, which is a refusal notice and not a preference (PC-36, PC-38).

  What a token means and what applying it changes belongs to the handler configured under `config :relay, RelayWeb.Links, handler: module`, a module implementing this behaviour. Without a handler every link is invalid. A sender's own links, Access's `email_verification` link among them, never come here: Relay passes them unchanged.
  """

  @typedoc "What a link does."
  @type kind :: :unsubscribe | :preference_change | :address_verification

  @typedoc "How a change was confirmed: by the confirmation page's form, by an RFC 8058 one-click request, or by the refusal on the unsubscribe page."
  @type source :: :confirmation_page | :rfc8058 | :unsubscribe_page

  @typedoc "Where an unsubscribe link's recipient stands: still in the category, out of it, or refusing the brand's commercial e-mail."
  @type state :: :open | :unsubscribed | :refused

  @typedoc "What a link is: its kind, the locale of its page and, for an unsubscribe link, its state."
  @type description :: %{
          required(:kind) => kind(),
          required(:locale) => String.t() | nil,
          optional(:state) => state()
        }

  @typedoc "The evidence of a change: its source and time, and the requesting address and user agent, redacted (PC-35)."
  @type evidence :: %{
          source: source(),
          at: DateTime.t(),
          ip: Relay.Redacted.t(),
          user_agent: Relay.Redacted.t() | nil
        }

  @doc "Describes a link without changing anything: its kind, the locale of the page and, for an unsubscribe link, its `state`; `:invalid` for a token that is unknown, revoked or malformed, `:unavailable` when it cannot be read now."
  @callback describe(token :: String.t()) ::
              {:ok, description()} | {:error, :invalid | :unavailable}

  @doc "Applies a link; applying an already applied link is `:ok` again (PC-35)."
  @callback apply_link(token :: String.t(), evidence()) :: :ok | {:error, :invalid | :unavailable}

  @doc "Applies the refusal the page of an unsubscribe link offers: no commercial e-mail of the brand at all (PC-36)."
  @callback refuse(token :: String.t(), evidence()) :: :ok | {:error, :invalid | :unavailable}

  @optional_callbacks refuse: 2

  # CH-76
  @doc "The configured handler; `RelayWeb.Links.Unconfigured` when there is none."
  @spec handler() :: module()
  def handler do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:handler, RelayWeb.Links.Unconfigured)
  end

  # PC-36
  @doc "Where the recipient manages its preferences, for the unsubscribe page; `nil` when no address is configured."
  @spec preferences_url() :: String.t() | nil
  def preferences_url do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:preferences_url)
  end
end
