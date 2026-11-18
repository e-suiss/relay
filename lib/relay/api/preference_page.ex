defmodule Relay.Api.PreferencePage do
  @moduledoc """
  The hosted preference page (X-51, X-18, PC-18): the page a subscriber opens from a link without signing in and without JavaScript. Its link carries a signed, expiring token that opens only this page for one subscriber (`Relay.Preferences.PageToken`), minted by `link/3` or `url/3`.

  The page renders from the same read as the embeddable component and the subscriber API (`Relay.Api.Preferences.view/2`): the cells with their locked, administrator and device settings states, the channel switches, the muted workflows and scope keys and the profile. Beside them it carries the subscriber's consents from Relay's consent copy, read only, since Access writes them (X-44). Every change the page makes is the subscriber's own preference write (`change/2`), applied in one transaction; no change writes a consent.
  """

  alias Relay.Api.Preferences
  alias Relay.Api.Store
  alias Relay.Api.Views

  @type model :: %{
          scope: Relay.Scope.t(),
          recipient_id: Relay.Id.t(),
          locale: String.t() | nil,
          preferences: map(),
          classes: %{String.t() => String.t()},
          consents: [map()],
          expires_at: DateTime.t()
        }
  @type failure :: :invalid | :expired | :unavailable

  @times ~r/\A([01][0-9]|2[0-3]):[0-5][0-9]\z/
  @days ~w(mon tue wed thu fri sat sun)
  @values ~w(opt_in opt_out)
  @choices ~w(instant digest none)

  # X-51
  # PC-18
  @doc "Mints a link to the page of the subscriber with `external_id` as the API answer, outside any transaction: the page address on Relay's public root and the instant the link expires."
  @spec link(Relay.Scope.t(), String.t(), String.t()) ::
          {:ok, {201, [], map()}} | {:error, Relay.Error.t()}
  def link(scope, external_id, root) do
    with {:ok, recipient_id} <- Preferences.locate(scope, external_id),
         {:ok, locale} <- locale(scope, recipient_id),
         {:ok, url, expires_at} <- url(scope, recipient_id, %{locale: locale, root: root}) do
      {:ok,
       {201, [],
        %{
          "object" => "preference_page_link",
          "subscriber_id" => Views.id("sub", recipient_id),
          "url" => url,
          "expires_at" => expires_at
        }}}
    end
  end

  defp locale(scope, recipient_id) do
    case Store.in_scope(scope, fn _status -> Relay.Subscribers.row(recipient_id) end) do
      {:ok, %{} = row} -> {:ok, row["locale"]}
      {:ok, nil} -> {:error, Preferences.subscriber_not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # X-51
  # X-22
  @doc "The page address of a subscriber under `root` on the self-explanatory path of `locale`, with a new token. Reaches the key store, so it never runs inside a transaction."
  @spec url(Relay.Scope.t(), Relay.Id.t(), %{locale: String.t() | nil, root: String.t()}) ::
          {:ok, String.t(), DateTime.t()} | {:error, Relay.Error.t()}
  def url(scope, recipient_id, %{locale: locale, root: root}) do
    case Relay.Preferences.issue_page_token(scope, recipient_id) do
      {:ok, token, claims} ->
        {:ok, String.trim_trailing(root, "/") <> path(locale) <> token, claims.expires_at}

      {:error, error} ->
        {:error, error}
    end
  end

  # X-22
  @doc "The path of the page for a locale, ending in `/`."
  @spec path(String.t() | nil) :: String.t()
  def path("tr" <> _rest), do: "/bildirim-tercihleri/"
  def path(_locale), do: "/notification-preferences/"

  # X-51
  # X-18
  # X-44
  @doc "Reads the page of a token without changing anything: the subscriber's preferences in the API read shape, its locale and its consents from the consent copy. `:expired` for a token past its instant, `:invalid` for one that does not verify or whose subscriber is gone."
  @spec read(String.t()) :: {:ok, model()} | {:error, failure()}
  def read(token) do
    with {:ok, claims} <- Relay.Preferences.verify_page_token(token) do
      claims.scope
      |> Store.in_scope(fn _status -> facts(claims.recipient_id) end)
      |> modelled(claims)
    end
  end

  defp modelled({:ok, %{} = facts}, claims), do: {:ok, model(claims, facts)}
  defp modelled({:ok, nil}, _claims), do: {:error, :invalid}
  defp modelled({:error, %Relay.Error{code: :not_found}}, _claims), do: {:error, :invalid}
  defp modelled({:error, _reason}, _claims), do: {:error, :unavailable}

  defp facts(recipient_id) do
    case Preferences.read(recipient_id) do
      nil -> nil
      preferences -> facts(recipient_id, preferences)
    end
  end

  defp facts(recipient_id, preferences) do
    %{
      preferences: Preferences.view(recipient_id, preferences),
      classes: Map.new(preferences.cells, &{&1["category_key"], &1["message_class"]}),
      locale: Relay.Subscribers.row(recipient_id)["locale"],
      consents: Relay.Preferences.consents(recipient_id)
    }
  end

  defp model(claims, facts) do
    %{
      scope: claims.scope,
      recipient_id: claims.recipient_id,
      locale: facts.locale,
      preferences: facts.preferences,
      classes: facts.classes,
      consents: facts.consents,
      expires_at: claims.expires_at
    }
  end

  # X-51
  # PC-17
  # PC-15
  # PC-6
  @doc """
  Applies one form action of the page as the subscriber's own write, in one transaction. The actions are `set` (`category`, `channel`, `value` `opt_in` or `opt_out`) for a cell of a category without a digest; `choose` (`category`, `channel`, `choice` `instant`, `digest` or `none`), the three choices of a digestible cell, of which `instant` and `digest` open the cell and choose the category's delivery and `none` closes it; `channel` (`channel`, `value` `opt_out` or `unset`) for a channel switch; `row_off` (`category`) closing every open cell of a category that is neither locked nor digestible; `unmute` (`level` `workflow` or `scope_key`, `key`); `quiet_hours` (`start`, `end`, every day), `quiet_hours_clear` and `quiet_hours_email` (`value` `true` or `false`). A cell the page does not show as changeable is refused.
  """
  @spec change(String.t(), map()) :: :ok | {:error, failure() | Relay.Error.t()}
  def change(token, form) when is_map(form) do
    with {:ok, claims} <- Relay.Preferences.verify_page_token(token) do
      claims.scope
      |> Store.in_scope(fn _status -> apply_form(claims.recipient_id, form) end)
      |> changed()
    end
  end

  defp changed({:ok, :ok}), do: :ok
  defp changed({:error, %Relay.Error{code: :not_found}}), do: {:error, :invalid}
  defp changed({:error, %Relay.Error{} = error}), do: {:error, error}
  defp changed({:error, :invalid}), do: {:error, :invalid}
  defp changed({:error, _reason}), do: {:error, :unavailable}

  defp apply_form(id, form) do
    with %{} = preferences <- Preferences.read(id) || {:error, :invalid},
         {:ok, body} <- body(form, Preferences.view(id, preferences)),
         {:ok, _answer} <- Preferences.update(id, body, :subscriber, Views.id("sub", id)) do
      :ok
    else
      {:error, error} -> Store.rollback(error)
    end
  end

  # X-51
  # PC-17
  # PC-6
  @doc "Whether the page offers a change of a cell: neither the tenant turned it off nor, in a locked category, is it the category's last open channel."
  @spec changeable?(map(), map()) :: boolean()
  def changeable?(%{"disabled_by_admin" => true}, _view), do: false

  def changeable?(%{"locked" => true, "effective" => true} = cell, view) do
    open = Enum.count(view["cells"], &(&1["category"] == cell["category"] and &1["effective"]))
    open > 1
  end

  def changeable?(_cell, _view), do: true

  defp body(%{"action" => "set", "value" => value} = form, view) when value in @values do
    with {:ok, cell} <- cell(form, view, false) do
      {:ok, %{"preferences" => [write(cell, value)]}}
    end
  end

  defp body(%{"action" => "choose", "choice" => choice} = form, view) when choice in @choices do
    with {:ok, cell} <- cell(form, view, true) do
      case choice do
        "none" ->
          {:ok, %{"preferences" => [write(cell, "opt_out")]}}

        delivery ->
          digest = Map.put(view["profile"]["digest"], cell["category"], delivery)
          {:ok, %{"preferences" => [write(cell, "opt_in")], "profile" => %{"digest" => digest}}}
      end
    end
  end

  defp body(%{"action" => "channel", "channel" => channel, "value" => value}, view)
       when value in ["opt_out", "unset"] do
    switch = %{"level" => "channel", "channel" => channel, "value" => value}

    if Enum.any?(view["cells"], &(&1["channel"] == channel)),
      do: {:ok, %{"preferences" => [switch]}},
      else: {:error, invalid("/channel")}
  end

  defp body(%{"action" => "row_off", "category" => category}, view) do
    row = Enum.filter(view["cells"], &(&1["category"] == category))
    open = Enum.filter(row, &(&1["effective"] and not &1["disabled_by_admin"]))

    if row != [] and open != [] and not Enum.any?(row, &(&1["locked"] or &1["digest_allowed"])),
      do: {:ok, %{"preferences" => Enum.map(open, &write(&1, "opt_out"))}},
      else: {:error, invalid("/category")}
  end

  defp body(%{"action" => "unmute", "level" => level, "key" => key}, view)
       when level in ["workflow", "scope_key"] do
    list = if level == "workflow", do: view["workflows"], else: view["scope_keys"]

    if Enum.any?(list, &(&1[level] == key)),
      do: {:ok, %{"preferences" => [%{"level" => level, level => key, "value" => "unset"}]}},
      else: {:error, invalid("/key")}
  end

  defp body(%{"action" => "quiet_hours", "start" => start, "end" => finish}, _view) do
    if Regex.match?(@times, start) and Regex.match?(@times, finish) and start != finish do
      ranges = Enum.map(@days, &%{"day" => &1, "start" => start, "end" => finish})
      {:ok, %{"profile" => %{"quiet_hours" => ranges}}}
    else
      {:error, invalid("/start")}
    end
  end

  defp body(%{"action" => "quiet_hours_clear"}, _view),
    do: {:ok, %{"profile" => %{"quiet_hours" => []}}}

  defp body(%{"action" => "quiet_hours_email", "value" => value}, _view)
       when value in ["true", "false"],
       do: {:ok, %{"profile" => %{"quiet_hours_email" => value == "true"}}}

  defp body(_form, _view), do: {:error, invalid("/action")}

  defp cell(%{"category" => category, "channel" => channel}, view, digest?)
       when is_binary(category) and is_binary(channel) do
    found =
      Enum.find(view["cells"], &(&1["category"] == category and &1["channel"] == channel))

    if found && found["digest_allowed"] == digest? && changeable?(found, view),
      do: {:ok, found},
      else: {:error, invalid("/category")}
  end

  defp cell(_form, _view, _digest?), do: {:error, invalid("/category")}

  defp write(cell, value) do
    %{
      "level" => "category_channel",
      "category" => cell["category"],
      "channel" => cell["channel"],
      "value" => value
    }
  end

  defp invalid(pointer) do
    error = %{pointer: pointer, code: "not_allowed", detail: "the page offers no such change"}
    Relay.Error.new(:validation_failed, "the change is not offered", %{errors: [error]})
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")
end
