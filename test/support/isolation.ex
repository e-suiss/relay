defmodule RelayTest.Isolation do
  @moduledoc """
  The negative isolation test generator (TN-16 (1), API-76, TN-15): every server API operation a router mounts that names a resource in its path is called with one credential against a resource of another scope, and must answer 404 without revealing that the resource exists. The cases come from the router and the contract, so an operation a later change mounts is covered without a new test. A path parameter needs a fixture that creates its resource in a given scope (`fixtures/0`); a mounted operation with a parameter that has none fails the generator, and so does an operation whose body has no entry in `bodies/0`.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Api, RelayTest.Api, RelayTest.IngestFixture],
    exports: []

  alias Relay.Api.Contract
  alias RelayTest.IngestFixture, as: F

  @parameter ~r/\{([a-z_]+)\}/
  @bodies [
    {"cancelEvent", %{}},
    {"cancelNotification", %{}},
    {"replaceSubscriber", %{"locale" => "tr-TR"}},
    {"updateSubscriber", %{"locale" => "tr-TR"}},
    {"publishWorkflow", %{}},
    {"replaceKillSwitch", %{"state" => "off", "reason" => "isolation", "ttl" => "PT1H"}},
    {"releaseKillSwitch", %{"reason" => "isolation"}},
    {"resumeKillSwitchDeliveries", %{"reason" => "isolation"}},
    {"cancelKillSwitchPausedDeliveries", %{"reason" => "isolation"}},
    {"replaceEventTypeMapping",
     %{
       "type" => "com.example.isolation",
       "workflow" => "isolation",
       "to_pointer" => "/to",
       "data_fields" => [""]
     }}
  ]
  @upserts ["replaceSubscriber"]

  @doc "The server operations with path parameters that `router` mounts, authenticated with a bearer token."
  @spec operations(module()) :: [Contract.operation()]
  def operations(router) do
    mounted = MapSet.new(RelayTest.Api.routes(router))

    for operation <- Contract.operations(),
        operation.family == :server and operation.security == :bearer,
        MapSet.member?(mounted, {operation.method, operation.path}),
        parameters(operation) != [],
        do: operation
  end

  @doc "The path parameters of an operation."
  @spec parameters(Contract.operation()) :: [String.t()]
  def parameters(operation),
    do: Enum.map(Regex.scan(@parameter, operation.path), fn [_, name] -> name end)

  @doc "The fixtures by path parameter: each creates its resource in a scope and returns its external identifier."
  @spec fixtures() :: %{String.t() => (Relay.Scope.t() -> String.t())}
  def fixtures do
    %{
      "kill_switch_id" => &kill_switch!/1,
      "event_id" => &event!(&1, :event),
      "notification_id" => &event!(&1, :notification),
      "delivery_id" => &event!(&1, :delivery),
      "subscriber_id" => &subscriber!/1,
      "workflow_key" => &workflow!/1,
      "version" => fn _scope -> "1" end,
      "mapping_id" => &mapping!/1
    }
  end

  @doc "The operations whose path names a resource they create when it is missing: the caller's own scope gets a new one (`201`) and the other scope's resource is never found."
  @spec upserts() :: [String.t()]
  def upserts, do: @upserts

  @doc "Request bodies by operation for operations that take one."
  @spec bodies() :: %{String.t() => map()}
  def bodies,
    do: @bodies |> Map.new() |> Map.put("replaceWorkflowDraft", %{"definition" => F.definition()})

  @doc "The path parameters of an operation without a fixture, and whether its body is missing."
  @spec gaps(Contract.operation()) :: [String.t()]
  def gaps(operation) do
    missing = Enum.reject(parameters(operation), &Map.has_key?(fixtures(), &1))
    body? = operation.request != %{} and not Map.has_key?(bodies(), operation.id)
    if body?, do: ["body" | missing], else: missing
  end

  @doc "Creates the resources an operation's path names in `scope` and returns the request path."
  @spec path(Contract.operation(), Relay.Scope.t()) :: String.t()
  def path(operation, scope) do
    ids = Map.new(parameters(operation), &{&1, Map.fetch!(fixtures(), &1).(scope)})
    Regex.replace(@parameter, operation.path, fn _match, name -> Map.fetch!(ids, name) end)
  end

  @doc "Calls an operation at `path` with `token` through `router`."
  @spec call(module(), Contract.operation(), String.t(), String.t()) :: Plug.Conn.t()
  def call(router, operation, path, token) do
    method = operation.method |> String.downcase() |> String.to_existing_atom()
    body = Map.get(bodies(), operation.id)
    key = {"idempotency-key", "isolation-" <> Base.encode16(:crypto.strong_rand_bytes(6))}

    headers = [key, {"if-match", ~s("999")}]

    conn =
      if body,
        do: body_request(operation, method, path, token, body, headers),
        else: RelayTest.Api.conn(method, path, nil, [bearer(token) | headers])

    RelayTest.Api.call(conn, router)
  end

  defp body_request(operation, method, path, token, body, headers) do
    [media | _] = Map.keys(operation.request)

    RelayTest.Api.conn(method, path, Jason.encode!(body), [
      {"content-type", media},
      bearer(token) | headers
    ])
  end

  defp bearer(token), do: {"authorization", "Bearer " <> token}

  defp owner(scope), do: F.token(scope)

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  @doc "Publishes a workflow in `scope` once per test process and returns its key; the other scope's calls never change it."
  @spec workflow!(Relay.Scope.t()) :: String.t()
  def workflow!(scope) do
    cache = {__MODULE__, :workflow, scope.tenant_id, scope.environment}

    case Process.get(cache) do
      nil ->
        key = "iso-" <> random()
        F.workflow!(scope, owner(scope), key)
        Process.put(cache, key)
        key

      key ->
        key
    end
  end

  @doc "Accepts an event in `scope` and returns the identifier of the event, its notification or its delivery."
  @spec event!(Relay.Scope.t(), :event | :notification | :delivery) :: String.t()
  def event!(scope, which) do
    token = owner(scope)
    to = [%{"id" => "iso-" <> random(), "email" => "i@example.com"}]
    body = %{"workflow" => workflow!(scope), "to" => to, "data" => %{"order" => "I-1"}}
    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]

    case which do
      :event ->
        accepted["id"]

      :notification ->
        notification

      :delivery ->
        path = "/v1/notifications/#{notification}/deliveries"
        [%{"id" => delivery}] = F.body(F.request(:get, path, token), 200)["data"]
        delivery
    end
  end

  @doc "Creates a subscriber in `scope` and returns its external identifier."
  @spec subscriber!(Relay.Scope.t()) :: String.t()
  def subscriber!(scope) do
    id = "iso-" <> random()
    body = %{"external_id" => id, "email" => "s@example.com"}
    F.body(F.request(:post, "/v1/subscribers", owner(scope), body), 201)
    id
  end

  @doc "Creates a CloudEvents type mapping in `scope` and returns its identifier."
  @spec mapping!(Relay.Scope.t()) :: String.t()
  def mapping!(scope) do
    body = %{
      "type" => "com.example.iso." <> random(),
      "workflow" => workflow!(scope),
      "to_pointer" => "/to",
      "data_fields" => [""]
    }

    created = F.request(:post, "/v1/event_type_mappings", owner(scope), body)
    F.body(created, 201)["id"]
  end

  @doc "Engages a tenant-scope kill switch in `scope` and returns its identifier."
  @spec kill_switch!(Relay.Scope.t()) :: String.t()
  def kill_switch!(scope) do
    id = Relay.Id.generate()
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    params = [
      id,
      "tenant",
      nil,
      nil,
      "all",
      nil,
      nil,
      nil,
      "off",
      nil,
      nil,
      "isolation",
      "INC-1",
      expires_at,
      nil,
      "operator",
      :crypto.strong_rand_bytes(32),
      "operator",
      "acc_op_1",
      "acc_op_1",
      nil
    ]

    {:ok, [%{"result" => "engaged"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.kill_switch_engage", params)
      end)

    Relay.ExternalId.encode("ksw", id)
  end
end
