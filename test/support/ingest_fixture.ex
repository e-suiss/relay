defmodule RelayTest.IngestFixture do
  @moduledoc "Helpers for tests of the send and management surface: requests through `RelayWeb.Router`, tokens with every server scope, and published workflows."

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.TemplateStore, Relay.Workflow, RelayWeb, RelayTest.Api],
    exports: []

  import ExUnit.Assertions

  alias Relay.Repo
  alias Relay.TemplateStore
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
        nil -> Api.conn(method, path, nil, Api.auth(token, method, path) ++ headers)
        body -> Api.json(method, path, token, body, headers)
      end

    Api.call(conn, RelayWeb.Router)
  end

  @doc "Decodes a response body after checking it against the operation's contract."
  @spec body(Plug.Conn.t(), pos_integer()) :: map()
  def body(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Api.assert_contract(conn)
    Jason.decode!(conn.resp_body)
  end

  @doc "A workflow definition with one channel step per channel; `message_class: nil` leaves the class out. The category defaults to `orders` for a `transactional` or absent class and to the class name otherwise."
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
      "category" => Keyword.get_lazy(opts, :category, fn -> category(opts) end),
      "message_class" => Keyword.get(opts, :message_class, "transactional"),
      "event_schema" =>
        Keyword.get(opts, :event_schema, %{
          "type" => "object",
          "properties" => %{"order" => %{"type" => "string"}},
          "required" => ["order"]
        }),
      "steps" => steps
    }
    |> Map.reject(fn {key, value} -> key == "message_class" and value == nil end)
  end

  defp category(opts) do
    case Keyword.get(opts, :message_class, "transactional") do
      class when class in [nil, "transactional"] -> "orders"
      class -> class
    end
  end

  # PC-57 (3)
  @doc "Creates a category through the API unless its key exists; the class defaults to `transactional`."
  @spec category!(String.t(), String.t(), String.t() | nil) :: :ok
  def category!(token, key, class \\ nil) do
    body = %{"key" => key, "name" => key, "message_class" => class || "transactional"}
    created = request(:post, "/v1/categories", token, body)
    assert created.status in [201, 409], created.resp_body
    :ok
  end

  @doc "Creates the category a definition names, as `category!/3` does."
  @spec category_of!(String.t(), map()) :: :ok
  def category_of!(token, definition),
    do: category!(token, definition["category"], definition["message_class"])

  @doc "Creates a workflow and its category through the API and publishes its draft through the gate, and publishes the `order-shipped` template its steps name unless the scope has it or `template: false` is given."
  @spec workflow!(Relay.Scope.t(), String.t(), String.t(), keyword()) :: map()
  def workflow!(scope, token, key, opts \\ []) do
    body = %{"key" => key, "definition" => definition(opts)}
    :ok = category_of!(token, body["definition"])

    if Keyword.get(opts, :template, true),
      do: :ok = template!(scope, "order-shipped", body["definition"]["category"])

    created = request(:post, "/v1/workflows", token, body)
    assert created.status == 201, created.resp_body
    publish!(scope, token, key)
  end

  @html ~s(<html><head><meta name="color-scheme" content="light"></head><body>Yolda</body></html>)

  @cells %{
    "sms" => %{"body" => "Siparişiniz kargoda."},
    "push" => %{"title" => "Sipariş", "body" => "Siparişiniz kargoda."},
    "web_push" => %{"title" => "Sipariş", "body" => "Siparişiniz kargoda."},
    "email" => %{
      "subject" => "Siparişiniz kargoda",
      "html_kind" => "raw_html",
      "html" => @html,
      "text" => "Siparişiniz kargoda."
    },
    "whatsapp" => %{
      "template_name" => "order_shipped",
      "language" => "tr",
      "parameters" => [%{"name" => "status", "value" => "kargoda"}]
    },
    "in_app" => %{"title" => "Sipariş", "body" => "Siparişiniz kargoda."},
    "webhook" => %{"body" => ~s({"status": "shipped"})},
    "voice" => %{"body" => "Siparişiniz kargoda."},
    "slack" => %{"body" => "Siparişiniz kargoda."},
    "teams" => %{"body" => "Siparişiniz kargoda."},
    "telegram" => %{"body" => "Siparişiniz kargoda."},
    "discord" => %{"body" => "Siparişiniz kargoda."}
  }

  @gate %{
    variables: %{"always" => [], "conditional" => []},
    measures: %{},
    findings: [],
    accept_warnings: false
  }

  @doc "A template definition with a `tr` cell on every channel, or the given `cells`: channel to cell, or channel to a map of locale to cell."
  @spec template_definition(map() | nil, keyword()) :: map()
  def template_definition(cells \\ nil, opts \\ []) do
    cells = cells || @cells

    %{
      "default_locale" => "tr",
      "sensitivity" => Keyword.get(opts, :sensitivity, "personal"),
      "cells" => Map.new(cells, fn {channel, cell} -> {channel, locales(cell)} end)
    }
    |> Map.merge(Map.new(Keyword.get(opts, :extra, [])))
  end

  defp locales(cell) do
    if Enum.all?(Map.keys(cell), &Regex.match?(~r/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/, &1)),
      do: cell,
      else: %{"tr" => cell}
  end

  # TP-48
  # TP-50
  @doc "Creates and publishes a template in a scope unless one exists at its key and level; `opts`: `:definition`, `:subtenant_id`."
  @spec template!(Relay.Scope.t(), String.t(), String.t(), keyword()) :: :ok
  def template!(scope, key, category, opts \\ []) do
    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    at = %{key: key, subtenant_id: opts[:subtenant_id], product: nil}

    attrs = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: key,
      subtenant_id: opts[:subtenant_id],
      name: "Template " <> key,
      category: category,
      definition: Keyword.get_lazy(opts, :definition, &template_definition/0)
    }

    {:ok, result} =
      Repo.in_scope(scope, fn _status ->
        case TemplateStore.template_create(attrs, digest(), actor) do
          {:created, _id, _version_id, version} ->
            {:published, _, _, _} =
              TemplateStore.template_publish(at, @gate, version, digest(), actor)

            :ok

          {:key_conflict, _id, _version_id, _version} ->
            :ok

          other ->
            other
        end
      end)

    assert result == :ok, inspect(result)
    :ok
  end

  @doc "Publishes a new version of a template in a scope from `definition`."
  @spec publish_template!(Relay.Scope.t(), String.t(), map(), keyword()) :: :ok
  def publish_template!(scope, key, definition, opts \\ []) do
    {:ok, actor} = Relay.Actor.new(:system, "relay-test", "relay-test")
    at = %{key: key, subtenant_id: opts[:subtenant_id], product: nil}

    {:ok, :ok} =
      Repo.in_scope(scope, fn _status ->
        %{"version" => version} = TemplateStore.template(key, opts[:subtenant_id])
        id = Relay.Id.generate()

        {:created, _, draft} =
          TemplateStore.template_draft_put(at, id, definition, version, digest(), actor)

        {:published, _, _, _} = TemplateStore.template_publish(at, @gate, draft, digest(), actor)
        :ok
      end)

    :ok
  end

  defp digest, do: :crypto.strong_rand_bytes(32)

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
