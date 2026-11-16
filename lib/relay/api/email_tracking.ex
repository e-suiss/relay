defmodule Relay.Api.EmailTracking do
  @moduledoc """
  The e-mail open and click tracking of a category or a template in the server API (CH-43, CH-44, DS-29, DS-32). Tracking is off without a setting; the tenant turns the open pixel and link wrapping on for a category or a template, and a template's setting replaces its category's at send time. A category or template of the `security` class is never trackable: turning either on is a field error, and a security subtype keeps tracking off at send time whatever the setting. With the open pixel on the view carries the `open_pixel_unreliable` warning. A change is audited as `setting.changed`.
  """

  alias Relay.Api.Gate
  alias Relay.TemplateStore

  @untrackable "security e-mails are never tracked"

  @type target :: String.t()
  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # DS-29
  # DS-32
  @doc "The API view of a tracking setting of a `category` or `template` of `class`; `nil` is no setting."
  @spec view(target(), String.t(), String.t(), map() | nil) :: map()
  def view(target, key, class, setting) do
    trackable = class != "security"
    open_pixel = trackable and is_map(setting) and setting["open_pixel"] == true
    wrap_links = trackable and is_map(setting) and setting["wrap_links"] == true

    %{
      "object" => "email_tracking",
      "target" => target,
      "key" => key,
      "open_pixel" => open_pixel,
      "wrap_links" => wrap_links,
      "trackable" => trackable,
      "warnings" => if(open_pixel, do: ["open_pixel_unreliable"], else: [])
    }
  end

  # DS-29
  @doc "Reads the tracking setting of a category or template."
  @spec get(Relay.Scope.t(), target(), String.t()) :: answer()
  def get(scope, target, key) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        setting_key = Relay.Channels.email_tracking_key(target, key)

        with {:ok, class} <- class(target, key),
             do: {:ok, class, TemplateStore.tenant_setting(setting_key)}
      end)

    case read do
      {:ok, {:ok, class, setting}} -> {:ok, {200, [], view(target, key, class, setting)}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # CH-43
  # CH-44
  # DS-29
  @doc "Replaces the tracking setting of a category or template inside the request's transaction."
  @spec put(Relay.Scope.t(), target(), String.t(), map(), Relay.Actor.t()) :: answer()
  def put(scope, target, key, body, actor) do
    value = %{
      "open_pixel" => body["open_pixel"] == true,
      "wrap_links" => body["wrap_links"] == true
    }

    with {:ok, class} <- class(target, key),
         :ok <- allowed(class, value) do
      setting_key = Relay.Channels.email_tracking_key(target, key)
      digest = Gate.digest(scope, "setting.changed", setting_key)
      _written = TemplateStore.tenant_setting_put(setting_key, value, digest, actor)
      {:ok, {200, [], view(target, key, class, value)}}
    end
  end

  defp class("category", key) do
    case Relay.Preferences.category(key) do
      %{"message_class" => class} -> {:ok, class}
      nil -> {:error, Relay.Error.new(:category_not_found, "no category has this key")}
    end
  end

  defp class("template", key) do
    case TemplateStore.template(key, nil) do
      %{"message_class" => class} -> {:ok, class}
      nil -> {:error, Relay.Error.new(:template_not_found, "no template has this key")}
    end
  end

  # CH-44
  defp allowed("security", value) do
    case Enum.find(["open_pixel", "wrap_links"], &(value[&1] == true)) do
      nil -> :ok
      field -> {:error, Gate.field_error("/" <> field, "not_allowed", @untrackable)}
    end
  end

  defp allowed(_class, _value), do: :ok
end
