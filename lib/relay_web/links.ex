defmodule RelayWeb.Links do
  @moduledoc """
  The owner of Relay's own one-time links (CH-76): one-click unsubscribe, a preference change and Relay's own address verification. A link opens Relay's confirmation page on its public root; `GET` only shows the page and never changes anything, so a security scanner that opens the link does not consume it, and the change is made by the page's `POST` (CH-44). The RFC 8058 `List-Unsubscribe-Post` request is applied directly, without a page (PC-35).

  What a token means and what applying it changes belongs to the handler configured under `config :relay, RelayWeb.Links, handler: module`, a module implementing this behaviour. Without a handler every link is invalid. A sender's own links, Access's `email_verification` link among them, never come here: Relay passes them unchanged.
  """

  @typedoc "What a link does."
  @type kind :: :unsubscribe | :preference_change | :address_verification

  @typedoc "How a change was confirmed: by the confirmation page's form, or by an RFC 8058 one-click request."
  @type source :: :confirmation_page | :rfc8058

  @typedoc "The evidence of a change: its source and time, and the requesting address and user agent, redacted (PC-35)."
  @type evidence :: %{
          source: source(),
          at: DateTime.t(),
          ip: Relay.Redacted.t(),
          user_agent: Relay.Redacted.t() | nil
        }

  @doc "Describes a link without changing anything: its kind and the locale of the page, or `:invalid` for a token that is unknown, revoked or malformed."
  @callback describe(token :: String.t()) ::
              {:ok, %{kind: kind(), locale: String.t() | nil}} | {:error, :invalid}

  @doc "Applies a link; applying an already applied link is `:ok` again (PC-35)."
  @callback apply_link(token :: String.t(), evidence()) :: :ok | {:error, :invalid | :unavailable}

  # CH-76
  @doc "The configured handler; `RelayWeb.Links.Unconfigured` when there is none."
  @spec handler() :: module()
  def handler do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:handler, RelayWeb.Links.Unconfigured)
  end
end
