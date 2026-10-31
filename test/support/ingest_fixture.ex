defmodule RelayTest.IngestFixture do
  @moduledoc "Helpers for tests of the send and management surface: requests through `RelayWeb.Router`, tokens with every server scope, and published workflows."

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Workflow, RelayWeb, RelayTest.Api],
    exports: []

  import ExUnit.Assertions

  alias Relay.Repo
  alias RelayTest.Api

  @scopes ["publish", "read", "subscribers", "config", "kill_switch"]

  @doc "A token for a scope with every server API scope, or the given ones."
  @spec token(Relay.Scope.t(), [String.t()]) :: String.t()
  def token(scope, scopes \\ @scopes), do: Api.token(scope, scopes)

  @doc "A fresh idempotency key header."
  @spec key() :: {String.t(), String.t()}
  def key, do: {"idempotency-key", "key-" <> Base.encode16(:crypto.strong_rand_bytes(8))}

  @doc "Sends a JSON request through `RelayWeb.Router`; writes get a fresh idempotency key unless `headers` names one."
  @spec request(atom(), String.t(), String.t(), term(), [{String.t(), String.t()}]) ::
          Plug.Conn.t()
  def request(method, path, token, body \\ nil, headers \\ []) do
    headers =
      if method in [:post, :put, :patch, :delete] and
           not List.keymember?(headers, "idempotency-key", 0),
         do: [key() | headers],
         else: headers

    conn =
      case body do
        nil -> Api.conn(method, path, nil, auth(token) ++ headers)
        body -> Api.json(method, path, token, body, headers)
      end

    Api.call(conn, RelayWeb.Router)
  end

  defp auth(nil), do: []
  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  @doc "Decodes a response body after checking it against the operation's contract."
  @spec body(Plug.Conn.t(), pos_integer()) :: map()
  def body(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Api.assert_contract(conn)
    Jason.decode!(conn.resp_body)
  end

  @doc "A workflow definition with one channel step per channel."
  @spec definition(keyword()) :: map()
  def definition(opts \\ []) do
    steps =
      for channel <- Keyword.get(opts, :channels, ["email"]) do
        %{
          "type" => "channel",
          "key" => channel <> "_step",
          "channel" => channel,
          "template" => "order-shipped"
        }
      end

    %{
      "name" => Keyword.get(opts, :name, "Order shipped"),
      "category" => Keyword.get(opts, :category, "orders"),
      "message_class" => Keyword.get(opts, :message_class, "transactional"),
      "event_schema" =>
        Keyword.get(opts, :event_schema, %{
          "type" => "object",
          "properties" => %{"order" => %{"type" => "string"}},
          "required" => ["order"]
        }),
      "steps" => steps
    }
  end

  @doc "Creates a workflow through the API and publishes its draft through the gate."
  @spec workflow!(Relay.Scope.t(), String.t(), String.t(), keyword()) :: map()
  def workflow!(scope, token, key, opts \\ []) do
    body = %{"key" => key, "definition" => definition(opts)}
    created = request(:post, "/v1/workflows", token, body)
    assert created.status == 201, created.resp_body
    publish!(scope, token, key)
  end

  @doc "Publishes a workflow's draft through the API and runs the publication gate."
  @spec publish!(Relay.Scope.t(), String.t(), String.t()) :: map()
  def publish!(scope, token, key) do
    current = request(:get, "/v1/workflows/" <> key, token)
    [etag] = Plug.Conn.get_resp_header(current, "etag")
    published = request(:post, "/v1/workflows/#{key}/publish", token, %{}, [{"if-match", etag}])
    assert published.status == 202, published.resp_body
    run_gates!(scope)
    Jason.decode!(request(:get, "/v1/workflows/" <> key, token).resp_body)
  end

  @doc "Runs every queued publication gate job of a scope."
  @spec run_gates!(Relay.Scope.t()) :: :ok
  def run_gates!(scope) do
    for [version_id] <- jobs("Relay.Workflow.PublishGate", scope, "version_id") do
      {:ok, id} = Relay.Id.parse(version_id)
      {:ok, _result} = Relay.Workflow.run_gate(scope, id)
    end

    :ok
  end

  @doc "The values of an argument of the jobs of a worker queued for a scope."
  @spec jobs(String.t(), Relay.Scope.t(), String.t()) :: [[term()]] | nil
  def jobs(worker, scope, arg) do
    Repo.query!(
      """
      SELECT args->>$3 FROM relay_queue.oban_jobs
      WHERE worker = $1 AND args->>'tenant_id' = $2 ORDER BY id
      """,
      [worker, Relay.Scope.tenant_text(scope), arg]
    ).rows
  end

  @doc "The delivery jobs queued for a delivery."
  @spec delivery_jobs(String.t()) :: [map()]
  def delivery_jobs(delivery_id) do
    {:ok, id} = Relay.ExternalId.decode(delivery_id, ["dlv"])

    Repo.query!(
      "SELECT args, queue FROM relay_queue.oban_jobs WHERE args->>'delivery_id' = $1",
      [Relay.Id.to_string(id)]
    ).rows
    |> Enum.map(fn [args, queue] -> Map.put(args, "queue", queue) end)
  end
end
