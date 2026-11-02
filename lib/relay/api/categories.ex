defmodule Relay.Api.Categories do
  @moduledoc """
  Categories on the server API (PC-57 (1), PC-57 (2), PC-57 (6)): list, create (`201`), read, a JSON Merge Patch under `If-Match`, archive, and the overrides of one sub-tenant. A category's key, message class and built-in flag never change. Settings the class does not allow are field errors: an expiry for `security`, a frequency limit outside `marketing`, `social` and `operational`, a digest outside `operational`; a lock outside `transactional`, `operational` and `action_required` is `category_lock_not_allowed` and a marketing category that defaults email, SMS, voice or WhatsApp to on is `category_default_forbidden`.
  """

  alias Relay.Api.Duration
  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @expires_min 60
  @expires_max 2_592_000
  @window_min 3_600
  @window_max 604_800
  @frequency_classes ~w(marketing social operational)

  # PC-57 (1)
  @doc "The API view of a category row."
  @spec view(map()) :: map()
  def view(c) do
    %{
      "object" => "category",
      "id" => Views.id("ctg", c["id"]),
      "key" => c["key"],
      "name" => c["name"],
      "message_class" => c["message_class"],
      "locked" => c["locked"],
      "enabled" => c["enabled"],
      "channel_defaults" => c["channel_defaults"],
      "default_expires_in" => Duration.iso(c["default_expires_in"]),
      "frequency" => frequency_view(c),
      "digest_allowed" => c["digest_allowed"],
      "state" => c["state"],
      "builtin" => c["builtin"],
      "version" => c["version"],
      "created_at" => c["created_at"],
      "updated_at" => c["updated_at"],
      "archived_at" => c["archived_at"]
    }
  end

  defp frequency_view(%{"frequency_limit" => nil}), do: nil

  defp frequency_view(row) do
    %{
      "limit" => row["frequency_limit"],
      "window" => Duration.iso(row["frequency_window"]),
      "fate" => row["frequency_fate"]
    }
  end

  # PC-57 (2)
  @doc "The API view of a sub-tenant's overrides of a category; `nil` is a sub-tenant without a setting."
  @spec setting_view(String.t(), Relay.Id.t(), map() | nil) :: map()
  def setting_view(key, subtenant_id, nil) do
    %{
      "object" => "category_subtenant_setting",
      "category" => key,
      "subtenant_id" => Views.id("stn", subtenant_id),
      "enabled" => nil,
      "channel_defaults" => nil,
      "frequency" => nil,
      "default_expires_in" => nil,
      "version" => 0,
      "created_at" => nil,
      "updated_at" => nil
    }
  end

  def setting_view(key, subtenant_id, s) do
    Map.merge(setting_view(key, subtenant_id, nil), %{
      "enabled" => s["enabled"],
      "channel_defaults" => s["channel_defaults"],
      "frequency" => frequency_view(s),
      "default_expires_in" => Duration.iso(s["default_expires_in"]),
      "version" => s["version"],
      "created_at" => s["created_at"],
      "updated_at" => s["updated_at"]
    })
  end

  @doc "The ETag header of a category version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # PC-57 (1)
  # PC-6
  @doc "Creates a category inside the request's transaction; `201` with its view."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, body, actor) do
    class = body["message_class"]

    with {:ok, settings} <- settings(body, class, :create) do
      attrs =
        Map.merge(settings, %{
          key: body["key"],
          name: body["name"],
          message_class: class,
          locked: Map.get(body, "locked", false),
          enabled: Map.get(body, "enabled", true),
          channel_defaults: Map.get(body, "channel_defaults", %{}),
          digest_allowed: Map.get(body, "digest_allowed", false)
        })

      case Relay.Preferences.create_category(scope, attrs, actor) do
        {:created, _id, version} ->
          location = {"location", "/v1/categories/" <> attrs.key}
          {:ok, {201, [etag(version), location], view(Relay.Preferences.category(attrs.key))}}

        {:key_conflict, _id, _version} ->
          {:error, Relay.Error.new(:resource_conflict, "a category with this key exists")}

        {:tenant_inactive, _id, _version} ->
          {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

        {refused, _id, _version} ->
          {:error, refused(refused)}
      end
    end
  end

  # PC-57 (1)
  # PC-11
  @doc "Applies a JSON Merge Patch to a category under its version inside the request's transaction."
  @spec update(Relay.Scope.t(), String.t(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def update(scope, key, body, expected_version, actor) do
    with {:ok, current} <- found(Relay.Preferences.category(key)),
         {:ok, attrs} <- merged(current, body) do
      case Relay.Preferences.update_category(scope, key, attrs, expected_version, actor) do
        {result, version} when result in [:updated, :unchanged] ->
          {:ok, {200, [etag(version)], view(Relay.Preferences.category(key))}}

        {:version_conflict, _version} ->
          {:error, Relay.Error.new(:precondition_failed, "the category changed; read it again")}

        {:not_found, _version} ->
          {:error, not_found()}

        {:archived, _version} ->
          {:error, archived()}

        {refused, _version} ->
          {:error, refused(refused)}
      end
    end
  end

  defp merged(current, body) do
    class = current["message_class"]
    base = current_settings(current)

    with {:ok, settings} <- settings(body, class, :patch) do
      {:ok,
       Map.merge(Map.merge(base, settings), %{
         name: Map.get(body, "name", current["name"]),
         locked: Map.get(body, "locked", current["locked"]),
         enabled: Map.get(body, "enabled", current["enabled"]),
         channel_defaults: channel_defaults(current["channel_defaults"], body),
         digest_allowed: Map.get(body, "digest_allowed", current["digest_allowed"])
       })}
    end
  end

  defp current_settings(current) do
    %{
      default_expires_in: current["default_expires_in"],
      frequency:
        current["frequency_limit"] &&
          %{
            limit: current["frequency_limit"],
            window: current["frequency_window"],
            fate: current["frequency_fate"]
          }
    }
  end

  defp channel_defaults(current, %{"channel_defaults" => patch}) when is_map(patch) do
    Enum.reduce(patch, current, fn
      {channel, nil}, acc -> Map.delete(acc, channel)
      {channel, value}, acc -> Map.put(acc, channel, value)
    end)
  end

  defp channel_defaults(current, _body), do: current

  # PC-57 (1)
  @doc "Archives a category inside the request's transaction; archiving an archived category returns it."
  @spec archive(Relay.Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def archive(scope, key, actor) do
    case Relay.Preferences.archive_category(scope, key, actor) do
      {result, version} when result in [:archived, :already_archived] ->
        {:ok, {200, [etag(version)], view(Relay.Preferences.category(key))}}

      {:builtin, _version} ->
        {:error,
         Relay.Error.new(:category_builtin, "the built-in security category cannot be archived")}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  # PC-57 (2)
  @doc "Replaces a sub-tenant's overrides of a category inside the request's transaction; `201` on first creation."
  @spec put_setting(Relay.Scope.t(), String.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def put_setting(scope, key, subtenant_id, body, actor) do
    with {:ok, category} <- found(Relay.Preferences.category(key)),
         :ok <- active(category),
         {:ok, settings} <- settings(body, category["message_class"], :setting) do
      attrs =
        Map.merge(settings, %{
          enabled: body["enabled"],
          channel_defaults: body["channel_defaults"]
        })

      case Relay.Preferences.put_subtenant_setting(scope, key, subtenant_id, attrs, actor) do
        {result, _version} when result in [:created, :updated, :unchanged] ->
          setting = Relay.Preferences.subtenant_setting(key, subtenant_id)
          {:ok, {written(result), [], setting_view(key, subtenant_id, setting)}}

        {:not_found, _version} ->
          {:error, not_found()}

        {:archived, _version} ->
          {:error, archived()}

        {:subtenant_not_found, _version} ->
          {:error, subtenant_not_found()}

        {refused, _version} ->
          {:error, refused(refused)}
      end
    end
  end

  defp written(:created), do: 201
  defp written(_result), do: 200

  # PC-57 (2)
  @doc "Reads a sub-tenant's overrides of a category."
  @spec get_setting(Relay.Scope.t(), String.t(), Relay.Id.t()) :: answer()
  def get_setting(scope, key, subtenant_id) do
    case Relay.Preferences.get_subtenant_setting(scope, key, subtenant_id) do
      {:ok, :not_found} -> {:error, not_found()}
      {:ok, :subtenant_not_found} -> {:error, subtenant_not_found()}
      {:ok, setting} -> {:ok, {200, [], setting_view(key, subtenant_id, setting)}}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  @doc "Reads a category."
  @spec get(Relay.Scope.t(), String.t()) :: answer()
  def get(scope, key) do
    case Relay.Preferences.get_category(scope, key) do
      {:ok, %{} = category} -> {:ok, {200, [etag(category["version"])], view(category)}}
      _missing -> {:error, not_found()}
    end
  end

  # API-56
  @doc "Lists categories."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    case Relay.Preferences.list_categories(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # PC-57 (1)
  # PC-57 (4)
  defp settings(body, class, mode) do
    errors =
      expires_errors(body, class) ++
        frequency_errors(body, class) ++ digest_errors(body, class, mode)

    if errors == [] do
      {:ok, Map.merge(expires(body), frequency(body))}
    else
      {:error,
       Relay.Error.new(:validation_failed, "the category breaks a field rule", %{errors: errors})}
    end
  end

  defp expires(%{"default_expires_in" => nil}), do: %{default_expires_in: nil}

  defp expires(%{"default_expires_in" => text}) do
    {:ok, interval} = Duration.to_interval(text)
    %{default_expires_in: interval}
  end

  defp expires(_body), do: %{}

  defp frequency(%{"frequency" => nil}), do: %{frequency: nil}

  defp frequency(%{"frequency" => f}) do
    {:ok, window} = Duration.to_interval(f["window"])
    %{frequency: %{limit: f["limit"], window: window, fate: f["fate"]}}
  end

  defp frequency(_body), do: %{}

  defp expires_errors(%{"default_expires_in" => text}, class) when is_binary(text) do
    cond do
      class == "security" ->
        [field("/default_expires_in", "not_allowed", "a security category has no expiry")]

      not within?(text, @expires_min, @expires_max) ->
        [field("/default_expires_in", "unsupported_value", "an expiry is PT1M to P30D")]

      true ->
        []
    end
  end

  defp expires_errors(_body, _class), do: []

  defp frequency_errors(%{"frequency" => %{"window" => window}}, class) do
    cond do
      class not in @frequency_classes ->
        [field("/frequency", "not_allowed", "only marketing, social and operational have one")]

      not within?(window, @window_min, @window_max) ->
        [field("/frequency/window", "unsupported_value", "a window is PT1H to P7D")]

      true ->
        []
    end
  end

  defp frequency_errors(_body, _class), do: []

  defp digest_errors(%{"digest_allowed" => true}, class, mode)
       when class != "operational" and mode != :setting,
       do: [field("/digest_allowed", "not_allowed", "only an operational category allows it")]

  defp digest_errors(_body, _class, _mode), do: []

  defp within?(text, min, max) do
    case Duration.to_ms(text) do
      {:ok, ms} -> ms >= min * 1_000 and ms <= max * 1_000
      :error -> false
    end
  end

  defp found(nil), do: {:error, not_found()}
  defp found(category), do: {:ok, category}

  defp active(%{"state" => "archived"}), do: {:error, archived()}
  defp active(_category), do: :ok

  defp refused(:lock_not_allowed),
    do:
      Relay.Error.new(
        :category_lock_not_allowed,
        "only transactional, operational and action_required categories can be locked"
      )

  defp refused(:default_forbidden),
    do:
      Relay.Error.new(
        :category_default_forbidden,
        "a marketing category cannot default email, sms, voice or whatsapp to on"
      )

  defp refused(:invalid_settings) do
    Relay.Error.new(:validation_failed, "the category breaks a field rule", %{
      errors: [field("", "unsupported_value", "the settings are not allowed for this class")]
    })
  end

  defp field(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  @doc "The error of an unknown category key."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:category_not_found, "no category has this key")

  @doc "The error of a change to an archived category."
  @spec archived() :: Relay.Error.t()
  def archived, do: Relay.Error.new(:category_archived, "the category is archived")

  @doc "The error of an unknown sub-tenant."
  @spec subtenant_not_found() :: Relay.Error.t()
  def subtenant_not_found, do: Relay.Error.new(:subtenant_not_found, "no subtenant has this id")
end
