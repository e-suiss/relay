defmodule Relay.Messaging.Install do
  @moduledoc """
  The provider side of a messaging installation, per workspace (CH-62): the OAuth authorize address and the code exchange of Slack and Discord, the webhook registration of Telegram, and the OAuth `state` that carries the installation's scope through the provider and back.

  The `state` is sealed under the region KEK inside the key store (`Relay.Keys.wrap/3`), bound to its purpose, and holds the tenant, environment, channel, channel identity, redirect address, actor and expiry; nothing about a pending installation is stored, so a `state` that does not unseal or has expired is refused. Every HTTP call is a provider call of `Relay.Channels.http_request/1`, never inside a transaction.

  The secret of a channel identity is JSON: Slack `{"client_secret", "signing_secret"}` with the app's client ID as the identity's `app_ref`; Discord `{"bot_token", "client_secret", "public_key"}` with the application ID; Telegram `{"bot_token"}`; Teams `{"app_id", "app_password", "tenant_id"}`.
  """

  alias Relay.Redacted

  @aad "relay.messaging.install.v1"
  @lifetime_s 600
  @slack_scopes "chat:write,im:write,channels:read,groups:read,users:read"
  @discord_permissions "3072"
  @telegram_updates ["message", "callback_query", "my_chat_member"]

  @type state :: %{
          tenant_id: Relay.Id.t(),
          environment: String.t(),
          channel: String.t(),
          identity_id: Relay.Id.t(),
          redirect_uri: String.t(),
          actor_ref: String.t(),
          expires_at: integer()
        }

  # CH-62
  @doc "Seals an installation's state for `now` (Unix seconds); it is valid for ten minutes."
  @spec seal(map(), integer()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def seal(attrs, now) do
    payload = %{
      "t" => Relay.Id.to_string(attrs.tenant_id),
      "e" => attrs.environment,
      "c" => attrs.channel,
      "i" => Relay.Id.to_string(attrs.identity_id),
      "r" => attrs.redirect_uri,
      "a" => attrs.actor_ref,
      "x" => now + @lifetime_s
    }

    with {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, sealed} <- Relay.Keys.wrap(kek, @aad, Redacted.wrap(Jason.encode!(payload))) do
      {:ok, Base.url_encode64(sealed, padding: false)}
    end
  end

  # CH-62
  @doc "Unseals an installation's state at `now`; a state that does not unseal or has expired is `:invalid`."
  @spec unseal(String.t(), integer()) :: {:ok, state()} | {:error, :invalid}
  def unseal(token, now) when is_binary(token) do
    with {:ok, sealed} <- Base.url_decode64(token, padding: false),
         {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, json} <- Relay.Keys.unwrap(kek, @aad, sealed),
         {:ok, %{"x" => expires} = p} when is_integer(expires) and expires >= now <-
           Jason.decode(Redacted.expose(json)),
         {:ok, tenant_id} <- Relay.Id.parse(p["t"]),
         {:ok, identity_id} <- Relay.Id.parse(p["i"]) do
      {:ok,
       %{
         tenant_id: tenant_id,
         environment: p["e"],
         channel: p["c"],
         identity_id: identity_id,
         redirect_uri: p["r"],
         actor_ref: p["a"],
         expires_at: expires
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def unseal(_token, _now), do: {:error, :invalid}

  @doc "How long a sealed state is valid, in seconds."
  @spec lifetime_s() :: pos_integer()
  def lifetime_s, do: @lifetime_s

  # CH-62
  @doc "The provider's OAuth authorize address of an installation."
  @spec authorize_url(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def authorize_url("slack", client_id, redirect_uri, state) do
    query = %{
      "client_id" => client_id,
      "scope" => @slack_scopes,
      "redirect_uri" => redirect_uri,
      "state" => state
    }

    "https://slack.com/oauth/v2/authorize?" <> URI.encode_query(query)
  end

  def authorize_url("discord", client_id, redirect_uri, state) do
    query = %{
      "client_id" => client_id,
      "scope" => "bot applications.commands",
      "permissions" => @discord_permissions,
      "response_type" => "code",
      "redirect_uri" => redirect_uri,
      "state" => state
    }

    "https://discord.com/oauth2/authorize?" <> URI.encode_query(query, :rfc3986)
  end

  # CH-62
  # TN-26
  @doc """
  Exchanges an OAuth code at the provider. Slack answers the workspace (`team.id`), the bot user and the bot token, which comes back redacted; Discord answers the server (`guild.id`) the bot was added to and no token is kept, since the bot token of the identity is the credential.
  """
  @spec exchange(String.t(), map(), String.t(), String.t(), keyword()) ::
          {:ok, %{workspace: String.t(), token: Redacted.t() | nil, settings: map()}}
          | {:error, String.t()}
  def exchange("slack", identity, code, redirect_uri, opts) do
    form = [
      client_id: identity.app_ref,
      client_secret: field(identity.secret, "client_secret"),
      code: code,
      redirect_uri: redirect_uri
    ]

    case post("https://slack.com/api/oauth.v2.access", [form: form], opts) do
      {:ok, %{"ok" => true, "access_token" => token, "team" => %{"id" => team}} = body}
      when is_binary(token) and is_binary(team) ->
        settings = %{"bot_user_id" => body["bot_user_id"], "scope" => body["scope"]}
        {:ok, %{workspace: team, token: Redacted.wrap(token), settings: settings}}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, error}

      {:ok, _other} ->
        {:error, "unexpected_response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def exchange("discord", identity, code, redirect_uri, opts) do
    form = [grant_type: "authorization_code", code: code, redirect_uri: redirect_uri]
    auth = {:basic, identity.app_ref <> ":" <> field(identity.secret, "client_secret")}

    case post("https://discord.com/api/v10/oauth2/token", [form: form, auth: auth], opts) do
      {:ok, %{"guild" => %{"id" => guild}}} when is_binary(guild) ->
        {:ok, %{workspace: guild, token: nil, settings: %{}}}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, error}

      {:ok, _other} ->
        {:error, "unexpected_response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def exchange(_channel, _identity, _code, _redirect_uri, _opts),
    do: {:error, "unsupported_channel"}

  # CH-62
  @doc "Registers a Telegram bot's webhook at `url` with its secret token and answers the bot's ID."
  @spec telegram(map(), String.t(), Redacted.t(), keyword()) ::
          {:ok, %{workspace: String.t(), token: nil, settings: map()}} | {:error, String.t()}
  def telegram(identity, url, secret_token, opts) do
    base = "https://api.telegram.org/bot" <> field(identity.secret, "bot_token") <> "/"

    hook = [
      json: %{
        "url" => url,
        "secret_token" => Redacted.expose(secret_token),
        "allowed_updates" => @telegram_updates
      }
    ]

    with {:ok, %{"ok" => true, "result" => %{"id" => id} = me}} <-
           post(base <> "getMe", [json: %{}], opts),
         {:ok, %{"ok" => true}} <- post(base <> "setWebhook", hook, opts) do
      settings = %{"bot_username" => me["username"]}
      {:ok, %{workspace: Integer.to_string(id), token: nil, settings: settings}}
    else
      {:ok, %{"description" => description}} when is_binary(description) -> {:error, description}
      {:ok, _other} -> {:error, "unexpected_response"}
      {:error, reason} -> {:error, reason}
    end
  end

  # CH-62
  @doc "The Telegram webhook secret token of a channel identity: derived from its bot token, so it is never stored."
  @spec telegram_secret(map()) :: Redacted.t()
  def telegram_secret(identity) do
    token = field(identity.secret, "bot_token")
    mac = :crypto.mac(:hmac, :sha256, token, "relay.telegram.webhook")
    Redacted.wrap(Base.url_encode64(mac, padding: false))
  end

  @doc "A string field of a channel identity's JSON secret, or the empty string."
  @spec field(Redacted.t(), String.t()) :: String.t()
  def field(secret, name) do
    with value when is_binary(value) <- Redacted.expose(secret),
         {:ok, %{} = decoded} <- Jason.decode(value),
         field when is_binary(field) <- Map.get(decoded, name) do
      field
    else
      _missing -> ""
    end
  end

  defp post(url, body, opts) do
    request =
      [method: :post, url: url, receive_timeout: 10_000, decode_body: false]
      |> Keyword.merge(body)
      |> Keyword.merge(Keyword.get(Application.get_env(:relay, Relay.Messaging, []), :http, []))
      |> Keyword.merge(opts)

    case Relay.Channels.http_request(request) do
      {:ok, %Req.Response{body: body}} -> {:ok, decode(body)}
      {:error, _exception} -> {:error, "provider_unreachable"}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
  end

  defp decode(_body), do: %{}
end
