defmodule Relay.Api.Messaging do
  @moduledoc """
  The messaging channel operations of the server API (CH-62, CH-4): a subscriber's conversation on Slack, Teams, Telegram or Discord (`/v1/subscribers/{id}/messaging_targets/{channel}`), the per-workspace installation of a channel identity (`/v1/messaging_installations` and the provider's redirect to `/v1/messaging_installations/callback`), the adapters with their versions and deprecation warnings (`/v1/channel_adapters`), and the inbound endpoint of the providers (`/inbound/v1/{channel}/{tenant}/{environment}/{channel_identity}`).

  A conversation's value is never returned. An installation answers the provider's authorize address (Slack, Discord) or the installed workspace (Telegram); a Teams installation is recorded from the bot's own installation update. An inbound interaction is acknowledged fast and recorded as an event only; it never approves anything (INV-29).
  """

  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # CH-62
  @doc "The API view of a conversation row."
  @spec view(map()) :: map()
  def view(t) do
    %{
      "object" => "messaging_target",
      "id" => Views.id("mtg", t["id"]),
      "subscriber_id" => Views.id("sub", t["recipient_id"]),
      "channel" => t["channel"],
      "provider_account_id" => Views.id("pva", t["provider_account_id"]),
      "state" => t["state"],
      "created_at" => t["created_at"],
      "updated_at" => t["updated_at"],
      "deleted_at" => t["deleted_at"]
    }
  end

  # CH-62
  # C-22
  @doc "Validates and seals a subscriber's conversation outside any transaction."
  @spec prepare_target(Relay.Scope.t(), Relay.Id.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_target(scope, recipient_id, channel, body) do
    with {:ok, account_id} <- account_id(body["provider_account_id"]),
         {:ok, value} <- conversation(channel, body["conversation"]) do
      case Relay.Messaging.prepare_target(scope, recipient_id, channel, account_id, value) do
        {:ok, plan} -> {:ok, plan}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  defp account_id(text) do
    case Relay.ExternalId.decode(text, ["pva"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, field("/provider_account_id", "invalid_format")}
    end
  end

  defp conversation(channel, value) do
    if Relay.Messaging.valid_target?(channel, value),
      do: {:ok, value},
      else: {:error, field("/conversation", "invalid_format")}
  end

  # CH-62
  @doc "Writes a prepared conversation inside the request's transaction; a new one is `201`, a replacement `200`."
  @spec write_target(map()) :: answer()
  def write_target(plan) do
    case Relay.Messaging.put_target(plan) do
      {:created, id} -> {:ok, {201, [], target(id)}}
      {:replaced, id} -> {:ok, {200, [], target(id)}}
      {:recipient_not_found, _id} -> {:error, subscriber_not_found()}
      {:account_not_found, _id} -> {:error, field("/provider_account_id", "not_found")}
      {:key_not_found, _id} -> {:error, unavailable()}
    end
  end

  # CH-62
  @doc "Disables a subscriber's conversation on a channel inside the request's transaction and answers it."
  @spec remove_target(Relay.Id.t(), String.t()) :: answer()
  def remove_target(recipient_id, channel) do
    if channel in Relay.Messaging.channels() do
      case Relay.Messaging.remove_target(recipient_id, channel, "messaging.target_removed") do
        {:disabled, id} -> {:ok, {200, [], target(id)}}
        {:not_found, _id} -> {:error, target_not_found()}
      end
    else
      {:error, target_not_found()}
    end
  end

  defp target(id), do: id |> Relay.Messaging.get_target() |> view()

  # CH-62
  @doc "Starts an installation outside any transaction; see `Relay.Messaging.start_install/5`. `base_url` is Relay's public address."
  @spec install(Relay.Scope.t(), map(), String.t(), Relay.Actor.t()) :: answer()
  def install(scope, body, base_url, actor) do
    with {:ok, identity_id} <- identity_id(body["channel_identity_id"]) do
      attrs = %{
        channel: body["channel"],
        identity_id: identity_id,
        redirect_uri: body["redirect_uri"] || base_url <> "/v1/messaging_installations/callback"
      }

      case Relay.Messaging.start_install(scope, attrs, base_url, actor) do
        {:ok, installation} -> {:ok, {201, [], installation(installation)}}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp identity_id(text) do
    case Relay.ExternalId.decode(text, ["chi"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, field("/channel_identity_id", "invalid_format")}
    end
  end

  # CH-62
  @doc "Completes a Slack or Discord installation from the provider's redirect; see `Relay.Messaging.complete_install/3`."
  @spec callback(map()) :: answer()
  def callback(%{"state" => state, "code" => code}) when is_binary(state) and is_binary(code) do
    case Relay.Messaging.complete_install(state, code) do
      {:ok, installation} -> {:ok, {200, [], installation(installation)}}
      {:error, error} -> {:error, error}
    end
  end

  def callback(_params), do: {:error, state_invalid()}

  defp installation(i) do
    %{
      "object" => "messaging_installation",
      "channel" => i.channel,
      "state" => i.state,
      "authorize_url" => Map.get(i, :authorize_url),
      "expires_at" => Map.get(i, :expires_at),
      "provider_account_id" => Views.id("pva", Map.get(i, :provider_account_id))
    }
  end

  # CH-4
  @doc "The registered adapters with their versions, deprecated provider APIs and whether the scope's warning is raised."
  @spec adapters(Relay.Scope.t()) :: answer()
  def adapters(scope) do
    case Relay.Messaging.adapters(scope) do
      {:ok, rows} ->
        {:ok, {200, [], %{"object" => "list", "data" => Enum.map(rows, &adapter/1)}}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp adapter(a) do
    %{
      "object" => "channel_adapter",
      "provider" => a.provider,
      "channels" => a.channels,
      "adapter_version" => a.adapter_version,
      "activated" => a.activated,
      "in_use" => a.in_use,
      "warning" => a.warning,
      "deprecations" => Enum.map(a.deprecations, &deprecation/1)
    }
  end

  defp deprecation(d), do: %{"api" => d["api"], "sunset_on" => d["sunset_on"]}

  # CH-62
  # WH-49
  @doc """
  Accepts a provider's inbound request on the raw body; see `Relay.Messaging.accept/2`. The path names the channel, the tenant (`ten_…`), the environment and the channel identity (`chi_…`). Returns the status and the JSON body to answer.
  """
  @spec inbound(map()) :: {pos_integer(), map()}
  def inbound(%{channel: channel} = request) do
    with true <- channel in Relay.Messaging.channels(),
         {:ok, tenant_id} <- Relay.ExternalId.decode(request.tenant, ["ten"]),
         {:ok, identity_id} <- Relay.ExternalId.decode(request.identity, ["chi"]),
         {:ok, environment} <- Relay.Environment.cast(request.environment) do
      accepted =
        Relay.Messaging.accept(
          Map.merge(request, %{
            tenant_id: tenant_id,
            environment: environment,
            identity_id: identity_id
          })
        )

      case accepted do
        {:ok, 200, body} -> {200, body}
        {:error, :unauthorized} -> {401, %{"error" => "unauthorized"}}
        {:error, :not_found} -> {404, %{"error" => "not_found"}}
        {:error, :unavailable} -> {503, %{"error" => "unavailable"}}
      end
    else
      _invalid -> {404, %{"error" => "not_found"}}
    end
  end

  defp field(pointer, code) do
    Relay.Error.new(:validation_failed, "the field is not valid", %{
      errors: [%{pointer: pointer, code: code, detail: "the field is not valid"}]
    })
  end

  defp subscriber_not_found,
    do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")

  @doc "The error of a conversation that is not found."
  @spec target_not_found() :: Relay.Error.t()
  def target_not_found,
    do: Relay.Error.new(:messaging_target_not_found, "the subscriber has no conversation here")

  defp state_invalid,
    do: Relay.Error.new(:messaging_install_state_invalid, "the installation state is not valid")

  defp unavailable do
    message = "the messaging channel could not be reached"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 1})
  end
end
