defmodule Relay.Api.EscalationPolicies do
  @moduledoc """
  Escalation policies on the server API (AG-17, AG-53): list, read, write a version under `If-Match`, list versions and archive. A policy is named and versioned: every write opens a new immutable version (`201` for the first, `200` after it), and a waitpoint keeps the version it pinned. The policy comes from its owner; Relay stores and applies it and takes no decision of its own.

  A tier is checked before it is stored: its `after` is a fixed duration from one minute to thirty days, every responder it adds exists, and a policy has at most `x-relay-limits waitpoint.max_escalation_tiers` tiers; more are `422 validation_failed` with `too_long`, the limit and the count sent. A stored tier keeps recipient identifiers, never external identifiers.
  """

  alias Relay.Api.Duration
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Responders
  alias Relay.Api.Views

  @min_after_ms 60_000
  @max_after_ms 2_592_000_000
  @states ["active", "archived"]

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type prepared :: %{tiers: [map()], names: Responders.names(), description: String.t() | nil}

  # AG-17
  @doc "The API view of an escalation policy row with its latest version; `names` are the external identifiers of its subscriber responders."
  @spec view(map(), Responders.names()) :: map()
  def view(p, names) do
    %{
      "object" => "escalation_policy",
      "id" => Views.id("esp", p["id"]),
      "key" => p["key"],
      "version" => p["version"],
      "state" => p["state"],
      "description" => p["description"],
      "tiers" => tiers_view(p["tiers"], names),
      "created_at" => p["created_at"],
      "updated_at" => p["updated_at"]
    }
  end

  # AG-17
  @doc "The API view of an escalation policy version row."
  @spec version_view(map(), Responders.names()) :: map()
  def version_view(v, names) do
    %{
      "object" => "escalation_policy_version",
      "key" => v["key"],
      "version" => v["version"],
      "description" => v["description"],
      "tiers" => tiers_view(v["tiers"], names),
      "created_at" => v["created_at"]
    }
  end

  # AG-17
  @doc "The API form of stored tiers."
  @spec tiers_view([map()], Responders.names()) :: [map()]
  def tiers_view(tiers, names) do
    for tier <- tiers do
      responders =
        for stored <- Map.get(tier, "add_responders", []),
            ref = Responders.view(stored, names),
            ref != nil,
            do: ref

      %{
        "after" => iso(tier["after_ms"]),
        "add_responders" => responders,
        "channels" => Map.get(tier, "channels", []),
        "repeat" => Map.get(tier, "repeat", 0),
        "skip_if_empty" => Map.get(tier, "skip_if_empty", true)
      }
    end
  end

  defp iso(ms), do: Duration.iso(%Postgrex.Interval{months: 0, days: 0, secs: div(ms, 1_000)})

  @doc "The ETag header of a policy version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # AG-17
  # AG-53
  @doc "Prepares a policy write outside any transaction: the tiers in their stored form, the names of their responders and the description; every invalid field is reported."
  @spec prepare(Relay.Scope.t(), map()) :: {:ok, prepared()} | {:error, Relay.Error.t()}
  def prepare(%Relay.Scope{} = scope, body) do
    with {:ok, tiers, names} <- tiers(scope, body["tiers"], "/tiers"),
         do: {:ok, %{tiers: tiers, names: names, description: body["description"]}}
  end

  # AG-12
  # AG-17
  # AG-53
  @doc "Reads the tiers of a request at `pointer` outside any transaction: `{:ok, stored, names}` with the tiers in their stored form and the names of their responders, or `validation_failed` with every invalid field."
  @spec tiers(Relay.Scope.t(), [map()], String.t()) ::
          {:ok, [map()], Responders.names()} | {:error, Relay.Error.t()}
  def tiers(%Relay.Scope{} = scope, tiers, pointer) when is_list(tiers) do
    %{limit: limit} = Relay.Agents.escalation_tier_limit()
    refs = for tier <- tiers, ref <- Map.get(tier, "add_responders", []), do: ref

    with :ok <- within(length(tiers), limit, pointer),
         {:ok, resolved} <- Responders.resolve(scope, refs) do
      read = tiers |> Enum.with_index() |> Enum.map(&tier(&1, resolved, pointer))

      case Enum.flat_map(read, &elem(&1, 1)) do
        [] -> {:ok, Enum.map(read, &elem(&1, 0)), Responders.names(resolved)}
        errors -> {:error, invalid(errors)}
      end
    end
  end

  # AG-53
  @doc "The error of more tiers than the limit: `validation_failed` with `too_long` at `pointer`, the limit and the count sent."
  @spec too_many(non_neg_integer(), String.t()) :: Relay.Error.t()
  def too_many(count, pointer) do
    %{limit: limit, path: path} = Relay.Agents.escalation_tier_limit()
    detail = "at most #{limit} escalation tiers (#{Enum.join(path, ".")})"
    invalid([%{pointer: pointer, code: "too_long", detail: detail, limit: limit, actual: count}])
  end

  defp within(count, limit, _pointer) when count <= limit, do: :ok
  defp within(count, _limit, pointer), do: {:error, too_many(count, pointer)}

  defp tier({tier, index}, resolved, pointer) do
    at = "#{pointer}/#{index}"
    {after_ms, after_errors} = after_ms(tier["after"], at <> "/after")

    {responders, responder_errors} =
      tier
      |> Map.get("add_responders", [])
      |> Enum.with_index()
      |> Enum.map(&responder(&1, resolved, at <> "/add_responders"))
      |> Enum.unzip()

    stored = %{
      "after_ms" => after_ms,
      "add_responders" => Enum.reject(responders, &is_nil/1),
      "channels" => Map.get(tier, "channels", []),
      "repeat" => Map.get(tier, "repeat", 0),
      "skip_if_empty" => Map.get(tier, "skip_if_empty", true)
    }

    {stored, after_errors ++ List.flatten(responder_errors)}
  end

  defp after_ms(text, at) do
    case Duration.to_ms(text) do
      {:ok, ms} when ms < @min_after_ms ->
        {nil, [error(at, "too_short", "a tier waits at least one minute")]}

      {:ok, ms} when ms > @max_after_ms ->
        {nil, [error(at, "too_long", "a tier waits at most thirty days")]}

      {:ok, ms} ->
        {ms, []}

      :error ->
        {nil, [error(at, "invalid_format", "not a duration of fixed length")]}
    end
  end

  defp responder({ref, index}, resolved, at) do
    case Map.get(resolved, ref) do
      nil -> {nil, [error("#{at}/#{index}", "not_found", "no such responder")]}
      id -> {Responders.stored(ref, id), []}
    end
  end

  # AG-17
  # T-59 (7)
  @doc "Writes a prepared version inside the request's transaction: `201` when it creates the policy, `200` for a later version."
  @spec put(Relay.Scope.t(), String.t(), prepared(), pos_integer() | nil, Relay.Actor.t()) ::
          answer()
  def put(%Relay.Scope{} = scope, key, prepared, expected_version, actor) do
    digest = digest(scope, "escalation_policy.put", key)
    attrs = %{tiers: prepared.tiers, description: prepared.description}

    key
    |> Relay.Agents.put_escalation_policy(attrs, expected_version, digest, actor)
    |> written(key, prepared)
  end

  defp written({:created, _id, version}, key, prepared) do
    headers = [etag(version), {"location", "/v1/escalation_policies/" <> key}]
    {:ok, {201, headers, view(Relay.Agents.escalation_policy(key), prepared.names)}}
  end

  defp written({:versioned, _id, version}, key, prepared),
    do: {:ok, {200, [etag(version)], view(Relay.Agents.escalation_policy(key), prepared.names)}}

  defp written({:version_conflict, _id, _version}, _key, _prepared),
    do: {:error, Relay.Error.new(:precondition_failed, "the policy changed; read it again")}

  defp written({:precondition_required, _id, _version}, _key, _prepared),
    do: {:error, Relay.Error.new(:precondition_required, "send If-Match with the ETag")}

  defp written({:archived, _id, _version}, _key, _prepared), do: {:error, archived()}

  defp written({:tier_limit, _id, _version}, _key, prepared),
    do: {:error, too_many(length(prepared.tiers), "/tiers")}

  defp written({:responder_not_found, _id, _version}, _key, _prepared),
    do: {:error, invalid([error("/tiers", "not_found", "a responder does not exist")])}

  defp written({:tenant_inactive, _id, _version}, _key, _prepared),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  # AG-17
  @doc "The names of the responders of a policy's latest version, read outside any transaction before `archive/5` shows the policy again."
  @spec names(Relay.Scope.t(), String.t()) ::
          {:ok, Responders.names()} | {:error, Relay.Error.t()}
  def names(%Relay.Scope{} = scope, key) do
    with {:ok, %{} = row} <- found(Relay.Agents.get_escalation_policy(scope, key)),
         do: Responders.read_names(scope, responders([row]))
  end

  # AG-17
  @doc "Archives a policy inside the request's transaction; archiving an archived policy returns it. `expected_version`, when given, must be the latest version."
  @spec archive(Relay.Scope.t(), String.t(), map(), integer() | nil, Relay.Actor.t()) ::
          answer()
  def archive(%Relay.Scope{} = scope, key, names, expected_version, actor) do
    case Relay.Agents.escalation_policy(key) do
      nil ->
        {:error, not_found()}

      %{"version" => version} when expected_version not in [nil, version] ->
        {:error, Relay.Error.new(:precondition_failed, "the policy changed; read it again")}

      %{"version" => version} ->
        digest = digest(scope, "escalation_policy.archived", key)
        {_result, _version} = Relay.Agents.archive_escalation_policy(key, digest, actor)
        {:ok, {200, [etag(version)], view(Relay.Agents.escalation_policy(key), names)}}
    end
  end

  # AG-17
  @doc "Reads a policy with its latest version."
  @spec get(Relay.Scope.t(), String.t()) :: answer()
  def get(%Relay.Scope{} = scope, key) do
    with {:ok, %{} = row} <- found(Relay.Agents.get_escalation_policy(scope, key)),
         {:ok, names} <- Responders.read_names(scope, responders([row])),
         do: {:ok, {200, [etag(row["version"])], view(row, names)}}
  end

  # AG-17
  # API-56
  @doc "Reads the `state` filter of a list request: `nil` without one."
  @spec state(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def state(%{"state" => state}) when state in @states, do: {:ok, state}

  def state(%{"state" => _other}),
    do: {:error, invalid([error("/state", "unsupported_value", "active or archived")])}

  def state(_query), do: {:ok, nil}

  # AG-17
  # API-56
  @doc "Lists policies with their latest version."
  @spec list(Relay.Scope.t(), String.t() | nil, Pagination.page(), String.t()) ::
          answer()
  def list(%Relay.Scope{} = scope, state, page, endpoint) do
    rows = Relay.Agents.list_escalation_policies(scope, state, page.cursor, page.limit)
    with {:ok, rows} <- read(rows), do: listed(scope, rows, page, endpoint, &view/2)
  end

  # AG-17
  # API-56
  @doc "Lists the versions of a policy, newest first."
  @spec versions(Relay.Scope.t(), String.t(), Pagination.page(), String.t()) ::
          answer()
  def versions(%Relay.Scope{} = scope, key, page, endpoint) do
    rows = Relay.Agents.escalation_policy_versions(scope, key, page.cursor, page.limit)
    with {:ok, rows} <- found(rows), do: listed(scope, rows, page, endpoint, &version_view/2)
  end

  defp listed(scope, rows, page, endpoint, view) do
    with {:ok, names} <- Responders.read_names(scope, responders(rows)),
         shown = &view.(&1, names),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, shown, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  defp responders(rows) do
    for %{"tiers" => tiers} <- rows,
        tier <- tiers,
        stored <- Map.get(tier, "add_responders", []),
        do: stored
  end

  defp found({:ok, nil}), do: {:error, not_found()}
  defp found(other), do: read(other)

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, _reason}), do: {:error, unavailable()}

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp invalid(errors),
    do: Relay.Error.new(:validation_failed, "the escalation policy is invalid", %{errors: errors})

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  @doc "The error of a write to a key that is not a policy key."
  @spec invalid_key() :: Relay.Error.t()
  def invalid_key do
    detail = "lower case letters and digits in groups joined by single hyphens"
    invalid([error("/policy_key", "invalid_format", detail)])
  end

  @doc "The error of an unknown policy key or version."
  @spec not_found() :: Relay.Error.t()
  def not_found,
    do: Relay.Error.new(:escalation_policy_not_found, "no escalation policy has this key")

  @doc "The error of a change to, or a new reference to, an archived policy."
  @spec archived() :: Relay.Error.t()
  def archived,
    do: Relay.Error.new(:escalation_policy_archived, "the escalation policy is archived")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
