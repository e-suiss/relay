defmodule Relay.Api.SmsDestinations do
  @moduledoc """
  The destination protections of `security` SMS on the server API (CH-54, E-33): the tenant's country allow-list and the stops the pumping detection opened.

  The allow-list is read with the countries of the tenant's region, which are always allowed, and replaced whole with the countries the tenant adds; it is held per tenant × environment as the setting `sms.security.allowed_countries` and a change is audited as `setting.changed`. A stop is listed and lifted with a reason; lifting is always an explicit action, audited as `sms_destination.released` and announced with the event of the same name, and a stop is never deleted. The operator surface reads and lifts through the same operations with an operator session.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope
  alias Relay.TemplateStore

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(active lifted)
  @max Relay.Limits.fetch!(["sms_destination", "max_allowed_countries"])
  @country ~r/\A[A-Z]{2}\z/

  # CH-54
  @doc "The API view of an allow-list."
  @spec policy_view(map()) :: map()
  def policy_view(%{region_countries: region, allowed_countries: allowed}) do
    %{
      "object" => "sms_destination_policy",
      "region_countries" => region,
      "allowed_countries" => allowed
    }
  end

  # CH-54
  @doc "Reads the allow-list of the scope."
  @spec get_policy(Scope.t()) :: answer()
  def get_policy(%Scope{} = scope) do
    case Relay.DestinationGuard.allow_list(scope) do
      {:ok, list} -> {:ok, {200, [], policy_view(list)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # CH-54
  @doc "Replaces the countries the tenant adds to its allow-list inside the request's transaction; every country that breaks a rule is a field error."
  @spec put_policy(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def put_policy(%Scope{} = scope, %{"allowed_countries" => countries}, actor)
      when is_list(countries) do
    case errors(countries) do
      [] ->
        key = Relay.DestinationGuard.allow_list_key()
        digest = Gate.digest(scope, "setting.changed", key)
        sorted = Enum.sort(countries)
        stored = if sorted == [], do: nil, else: sorted
        _written = TemplateStore.tenant_setting_put(key, stored, digest, actor)
        region = Relay.DestinationGuard.region_countries()
        {:ok, {200, [], policy_view(%{region_countries: region, allowed_countries: sorted})}}

      errors ->
        message = "the countries break a field rule"
        {:error, Relay.Error.new(:validation_failed, message, %{errors: errors})}
    end
  end

  def put_policy(_scope, _body, _actor) do
    detail = "allowed_countries is a list of countries"
    {:error, Gate.field_error("/allowed_countries", "required", detail)}
  end

  # CH-54
  @doc "The field errors of a list of added countries: too many, a value that is not an ISO 3166-1 alpha-2 code, or a country named twice."
  @spec errors([term()]) :: [map()]
  def errors(countries) when is_list(countries) do
    count =
      if length(countries) > @max,
        do: [error("/allowed_countries", "too_long", "at most #{@max} countries")],
        else: []

    {_seen, each} =
      countries
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {country, index}, {seen, acc} ->
        pointer = "/allowed_countries/#{index}"
        {MapSet.put(seen, country), acc ++ country_errors(country, seen, pointer)}
      end)

    count ++ each
  end

  defp country_errors(country, seen, pointer) do
    cond do
      not (is_binary(country) and Regex.match?(@country, country)) ->
        [error(pointer, "invalid_format", "a country is an ISO 3166-1 alpha-2 code")]

      MapSet.member?(seen, country) ->
        [error(pointer, "conflict", "the country is already on the list")]

      true ->
        []
    end
  end

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  # CH-54
  @doc "The API view of a stop row."
  @spec view(map()) :: map()
  def view(s) do
    %{
      "object" => "sms_destination_stop",
      "id" => Views.id("sds", s["id"]),
      "kind" => s["kind"],
      "value" => s["value"],
      "country" => s["country"],
      "rule_id" => s["rule_id"],
      "detail" => s["detail"],
      "state" => s["state"],
      "created_at" => s["created_at"],
      "lifted_at" => s["lifted_at"],
      "lifted_by" => s["lifted_by_ref"],
      "lift_reason" => s["lift_reason"]
    }
  end

  # CH-54
  @doc "Reads the `state` filter of a list request."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # CH-54
  # API-56
  @doc "Lists stops, newest first."
  @spec list(Scope.t(), String.t() | nil, Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, state, page, endpoint) do
    case Relay.DestinationGuard.list_stops(scope, state, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # CH-54
  @doc "Lifts a stop with a reason inside the request's transaction; lifting a lifted stop returns it."
  @spec lift(Scope.t(), Relay.Id.t(), String.t(), Relay.Actor.t()) :: answer()
  def lift(%Scope{} = scope, id, reason, actor) do
    digest = Gate.digest(scope, "sms_destination.released", Relay.Id.to_string(id))

    case Relay.DestinationGuard.lift(id, reason, digest, actor) do
      :not_found -> {:error, not_found()}
      _lifted -> {:ok, {200, [], view(Relay.DestinationGuard.stop_here(id))}}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown stop identifier."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:sms_destination_stop_not_found, "no stop has this id")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
