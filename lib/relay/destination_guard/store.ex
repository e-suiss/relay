defmodule Relay.DestinationGuard.Store do
  @moduledoc """
  Data access of the destination protections of `security` SMS (CH-54): the tenant's region and the countries it added, and the stops of a number block or a country. A stop is written only through `relay_fn.sms_destination_stop_open` and `relay_fn.sms_destination_stop_lift`, each of which writes the stop, its audit record and its outbox event in one transaction, and is never deleted. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @key "sms.security.allowed_countries"
  @opened ~w(opened exists recently_lifted)a
  @lifted ~w(lifted already_lifted not_found)a
  @columns "s.id, s.kind, s.value, s.country, s.rule_id, s.detail, s.state, s.lifted_at, s.lifted_by_ref, s.lift_reason, s.created_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "The setting key of the countries a tenant added to its allow-list."
  @spec key() :: String.t()
  def key, do: @key

  # CH-54
  @doc "The tenant's region as text, or `nil` when the tenant row cannot be seen."
  @spec region() :: String.t() | nil
  def region do
    case all("SELECT t.region::text AS region FROM relay.tenants t", []) do
      [%{"region" => region}] -> region
      _none -> nil
    end
  end

  # CH-54
  @doc "The countries the tenant added to its allow-list, `[]` when it added none."
  @spec added_countries() :: [String.t()]
  def added_countries do
    sql = "SELECT s.value FROM relay.settings s WHERE s.subtenant_id IS NULL AND s.key = $1"

    case all(sql, [@key]) do
      [%{"value" => countries}] when is_list(countries) -> Enum.filter(countries, &is_binary/1)
      _none -> []
    end
  end

  # CH-54
  @doc "The active stops of a country and of the number blocks among `prefixes`, a country stop first."
  @spec match(String.t(), [String.t()]) :: [map()]
  def match(country, prefixes),
    do: Repo.call!("relay_fn.sms_destination_stop_match", [country, prefixes])

  # CH-54
  # E-33
  @doc "Opens a stop with its audit record and its `sms_destination.stopped` event; `stop` carries `:kind`, `:value`, `:country`, `:rule_id` and `:detail`. A destination lifted within `grace_s` seconds is not stopped again. Returns the result, the stop's identifier and, for an opened stop, how many number blocks of its country were stopped within `escalation_s` seconds."
  @spec open(map(), non_neg_integer(), non_neg_integer(), binary(), Actor.t()) ::
          {:opened | :exists | :recently_lifted, id() | nil, non_neg_integer() | nil}
  def open(stop, grace_s, escalation_s, digest, %Actor{} = actor) do
    params =
      [
        stop.id,
        stop.kind,
        stop.value,
        stop.country,
        stop.rule_id,
        stop.detail,
        grace_s,
        escalation_s,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.sms_destination_stop_open", params)
    {Repo.code!(row["result"], @opened), row["stop_id"], row["country_prefix_stops"]}
  end

  # CH-54
  @doc "Lifts a stop with a reason, its audit record and its `sms_destination.released` event."
  @spec lift(id(), String.t(), binary(), Actor.t()) :: :lifted | :already_lifted | :not_found
  def lift(id, reason, digest, %Actor{} = actor) do
    params = [id, reason, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.sms_destination_stop_lift", params)
    Repo.code!(row["sms_destination_stop_lift"], @lifted)
  end

  # CH-54
  @doc "Reads a stop, or `nil`."
  @spec get(id()) :: map() | nil
  def get(id) do
    case all("SELECT #{@columns} FROM relay.sms_destination_stops s WHERE s.id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # CH-54
  # API-56
  @doc "A page of stops, newest first, optionally of one state; at most `limit + 1` rows, each with its `cursor_at`."
  @spec list(String.t() | nil, cursor(), pos_integer()) :: [map()]
  def list(state, cursor, limit) do
    {condition, order, params} = window(cursor, [state])

    sql = """
    SELECT #{@columns}, s.created_at AS cursor_at FROM relay.sms_destination_stops s
    WHERE ($1::text IS NULL OR s.state = $1)#{condition}
    ORDER BY s.created_at #{order}, s.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp window(nil, params), do: {"", "DESC", params}

  defp window(%{direction: :after, sort_ts_us: ts, id: id}, params),
    do: {" AND (s.created_at, s.id) < ($2, $3)", "DESC", params ++ [from_us(ts), id]}

  defp window(%{direction: :before, sort_ts_us: ts, id: id}, params),
    do: {" AND (s.created_at, s.id) > ($2, $3)", "ASC", params ++ [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
