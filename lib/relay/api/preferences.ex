defmodule Relay.Api.Preferences do
  @moduledoc """
  A subscriber's preferences and consent copy on the server and subscriber APIs (PC-57 (5), PC-57 (6), PC-59 (1)). The read shape has one cell for every active category other than `system` and every channel, the channel, workflow and scope key switches and the profile. A tenant writes only `opt_out` on behalf of a subscriber (`preference_direction_forbidden`); the subscriber writes any value and its profile. Closing the last open channel of a locked category is `preference_last_channel`. The writes of one request apply together or not at all. Consents are read only.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type writer :: :tenant | :subscriber

  @external_id ~r/\A[\x21-\x7E]{1,256}\z/
  @keys %{"category_channel" => "category", "workflow" => "workflow", "scope_key" => "scope_key"}
  @fields ~w(category channel workflow scope_key)
  @needs %{
    "category_channel" => ~w(category channel),
    "channel" => ~w(channel),
    "workflow" => ~w(workflow),
    "scope_key" => ~w(scope_key)
  }

  # PC-57 (5)
  # PC-12
  @doc "The API view of a recipient's preferences."
  @spec view(Relay.Id.t(), map()) :: map()
  def view(recipient_id, %{cells: cells, switches: switches, profile: profile}) do
    %{
      "object" => "subscriber_preferences",
      "subscriber_id" => Views.id("sub", recipient_id),
      "cells" => Enum.map(cells, &cell/1),
      "channels" => for(%{"level" => "channel"} = s <- switches, do: channel(s)),
      "workflows" => for(%{"level" => "workflow"} = s <- switches, do: workflow(s)),
      "scope_keys" => for(%{"level" => "scope_key"} = s <- switches, do: scope_key(s)),
      "profile" => profile_view(profile)
    }
  end

  defp cell(c) do
    %{
      "category" => c["category_key"],
      "channel" => c["channel"],
      "value" => c["value"],
      "effective" => c["effective"],
      "source" => c["source"]
    }
  end

  defp channel(s), do: %{"channel" => s["channel"], "value" => s["value"]}
  defp workflow(s), do: %{"workflow" => s["key"], "value" => s["value"]}
  defp scope_key(s), do: %{"scope_key" => s["key"], "value" => s["value"]}

  defp profile_view(nil), do: profile_view(Relay.Preferences.default_profile())

  defp profile_view(p) do
    %{
      "quiet_hours" => p["quiet_hours"],
      "schedule" => p["schedule"],
      "dnd_until" => p["dnd_until"],
      "quiet_hours_email" => p["quiet_hours_email"],
      "digest" => p["digest"]
    }
  end

  # API-66
  @doc "The subscriber of an external identifier, found outside any transaction; an unknown one is `subscriber_not_found`."
  @spec locate(Relay.Scope.t(), String.t()) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def locate(scope, external_id) do
    if Regex.match?(@external_id, external_id) do
      case Relay.Subscribers.locate(scope, external_id) do
        {:ok, <<_::128>> = id} -> {:ok, id}
        _missing -> {:error, subscriber_not_found()}
      end
    else
      {:error, subscriber_not_found()}
    end
  end

  # PC-57 (5)
  @doc "Reads a subscriber's preferences."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, recipient_id) do
    case Relay.Preferences.get_preferences(scope, recipient_id) do
      {:ok, %{} = preferences} -> {:ok, {200, [], view(recipient_id, preferences)}}
      {:ok, nil} -> {:error, subscriber_not_found()}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # PC-57 (5)
  # PC-15
  # PC-6
  @doc "Writes preferences of a subscriber inside the request's transaction as `writer`, with `actor_ref` in each change record; the profile only as the subscriber. Answers the read shape."
  @spec update(Relay.Id.t(), map(), writer(), String.t()) :: answer()
  def update(recipient_id, body, writer, actor_ref) do
    with {:ok, writes} <- writes(Map.get(body, "preferences", [])),
         :ok <- subscriber(recipient_id),
         :ok <- write(recipient_id, writes, writer, actor_ref),
         :ok <- profile(recipient_id, body["profile"]) do
      {:ok, {200, [], view(recipient_id, Relay.Preferences.preferences(recipient_id))}}
    end
  end

  defp subscriber(recipient_id) do
    if Relay.Preferences.subscriber?(recipient_id),
      do: :ok,
      else: {:error, subscriber_not_found()}
  end

  defp writes(rows) do
    {writes, errors} =
      rows
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {row, index}, errors ->
        {to_write(row), errors ++ shape_errors(row, index)}
      end)

    if errors == [] do
      {:ok, writes}
    else
      {:error,
       Relay.Error.new(:validation_failed, "a preference write is invalid", %{errors: errors})}
    end
  end

  defp to_write(row) do
    level = row["level"]

    %{
      level: level,
      key: @keys[level] && row[@keys[level]],
      channel: if(level in ["category_channel", "channel"], do: row["channel"]),
      value: row["value"]
    }
  end

  defp shape_errors(row, index) do
    needed = Map.fetch!(@needs, row["level"])
    base = "/preferences/#{index}/"

    missing =
      needed
      |> Enum.reject(&Map.has_key?(row, &1))
      |> Enum.map(&%{pointer: base <> &1, code: "required", detail: "#{&1} is required"})

    extra =
      (@fields -- needed)
      |> Enum.filter(&Map.has_key?(row, &1))
      |> Enum.map(&%{pointer: base <> &1, code: "not_allowed", detail: "#{&1} is not allowed"})

    missing ++ extra
  end

  defp write(recipient_id, writes, writer, actor_ref) do
    case Relay.Preferences.write_preferences(recipient_id, writes, writer(writer), actor_ref) do
      :ok -> :ok
      {:refused, refused, index} -> {:error, refused(refused, index)}
    end
  end

  defp writer(:tenant), do: "tenant"
  defp writer(:subscriber), do: "subscriber"

  defp refused(:direction_forbidden, _index),
    do: Relay.Error.new(:preference_direction_forbidden, "a tenant may only write opt_out")

  defp refused(:last_channel, _index),
    do: Relay.Error.new(:preference_last_channel, "a locked category keeps one channel open")

  defp refused(:category_not_found, _index),
    do: Relay.Error.new(:category_not_found, "no category has this key")

  defp refused(:recipient_not_found, _index), do: subscriber_not_found()

  defp profile(_recipient_id, nil), do: :ok

  defp profile(recipient_id, changes) do
    changes =
      case changes do
        %{"dnd_until" => text} when is_binary(text) ->
          {:ok, at, _offset} = DateTime.from_iso8601(text)
          Map.put(changes, "dnd_until", at)

        _other ->
          changes
      end

    case Relay.Preferences.write_profile(recipient_id, changes, "subscriber") do
      :ok ->
        :ok

      {:refused, :digest_not_allowed} ->
        {:error,
         Relay.Error.new(
           :preference_digest_not_allowed,
           "a digest can be chosen only for social and digest-allowed operational categories"
         )}

      {:refused, :recipient_not_found} ->
        {:error, subscriber_not_found()}

      {:refused, _invalid} ->
        {:error,
         Relay.Error.new(:validation_failed, "the profile is invalid", %{
           errors: [
             %{
               pointer: "/profile",
               code: "invalid_format",
               detail: "a time range starts and ends at different times"
             }
           ]
         })}
    end
  end

  # PC-59 (1)
  # PC-21
  @doc "The API view of a current consent row."
  @spec consent_view(map()) :: map()
  def consent_view(c) do
    %{
      "object" => "consent",
      "id" => Views.id("cns", c["consent_id"]),
      "brand" => Views.id("stn", c["brand_subtenant_id"]),
      "channel" => c["channel"],
      "status" => c["status"],
      "consent_kind" => c["consent_kind"],
      "recipient_type" => c["recipient_type"],
      "source" => c["source"],
      "occurred_at" => c["occurred_at"]
    }
  end

  # PC-59 (1)
  # API-56
  @doc "Lists the current consents of a subscriber, newest first."
  @spec consents(Relay.Scope.t(), Relay.Id.t(), Relay.Api.Pagination.page(), String.t()) ::
          answer()
  def consents(scope, recipient_id, page, endpoint) do
    case Relay.Preferences.get_consents(scope, recipient_id) do
      {:ok, rows} when is_list(rows) ->
        position = &{&1["occurred_at"], &1["consent_id"]}
        rows = window(rows, page)

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &consent_view/1, position),
             do: {:ok, {200, [], body}}

      {:ok, nil} ->
        {:error, subscriber_not_found()}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp window(rows, %{cursor: cursor, limit: limit}) do
    sorted = Enum.sort_by(rows, &sort_key/1, :desc)

    case cursor do
      nil ->
        Enum.take(sorted, limit + 1)

      %{direction: :after, sort_ts_us: ts, id: id} ->
        sorted |> Enum.filter(&(sort_key(&1) < {ts, id})) |> Enum.take(limit + 1)

      %{direction: :before, sort_ts_us: ts, id: id} ->
        sorted
        |> Enum.filter(&(sort_key(&1) > {ts, id}))
        |> Enum.reverse()
        |> Enum.take(limit + 1)
        |> Enum.reverse()
    end
  end

  defp sort_key(row), do: {DateTime.to_unix(row["occurred_at"], :microsecond), row["consent_id"]}

  @doc "The error of an unknown subscriber."
  @spec subscriber_not_found() :: Relay.Error.t()
  def subscriber_not_found, do: Relay.Error.new(:subscriber_not_found, "no such subscriber")
end
