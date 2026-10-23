defmodule Relay.Datasets.StoreTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.Datasets.Package
  alias Relay.Datasets.Schema
  alias Relay.Datasets.Version
  alias RelayTest.TenantFixture

  @moduletag :tmp_dir

  @schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "required" => ["rows"],
    "properties" => %{
      "rows" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["code", "retry"],
          "properties" => %{"code" => %{"type" => "string"}, "retry" => %{"type" => "boolean"}}
        }
      }
    }
  }

  defp define!(scopes, schema \\ @schema) do
    name = "ds_" <> TenantFixture.random()
    {:ok, digest} = Schema.digest(schema)
    conn = Relay.SqlCase.connect(:admin)

    Postgrex.query!(
      conn,
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, $4, now())",
      [name, schema, digest, scopes]
    )

    GenServer.stop(conn)
    name
  end

  defp content(code, retry \\ true), do: %{"rows" => [%{"code" => code, "retry" => retry}]}

  defp publish(scope, name, content, opts \\ []) do
    Datasets.publish(
      scope,
      name,
      content,
      TenantFixture.actor(),
      Keyword.merge([source_ref: "test"], opts)
    )
  end

  defp operator do
    {:ok, actor} = Relay.Actor.new(:installation_operator, "acc_op_1", "acc_op_1")
    actor
  end

  setup do
    TenantFixture.as_role("relay_worker")
    %{tenant: TenantFixture.tenant!()}
  end

  describe "OP-65 publication and activation" do
    test "OP-65: content is validated against the data set schema before it is published", %{
      tenant: t
    } do
      name = define!(["tenant"])

      assert {:error, %Relay.Error{code: :invalid_content}} =
               publish(t.live, name, %{"rows" => [%{"code" => 1}]})

      assert {:error, %Relay.Error{code: :not_canonical}} =
               publish(t.live, name, %{"rows" => [], "rate" => 0.5})

      assert {:error, %Relay.Error{code: :dataset_not_found}} =
               publish(t.live, "ds_missing", content("a"))

      assert {:ok, {:published, v1, 1}} = publish(t.live, name, content("a"))
      assert {:ok, {:exists, ^v1, 1}} = publish(t.live, name, content("a"))
      assert {:ok, {:published, _v2, 2}} = publish(t.live, name, content("b"))
    end

    test "OP-65: one version is active per scope, and environments are separate scopes", %{
      tenant: t
    } do
      name = define!(["tenant"])
      assert Datasets.active(t.live, name) == {:ok, nil}
      {:ok, {:published, v1, 1}} = publish(t.live, name, content("a"))
      {:ok, {:published, v2, 2}} = publish(t.live, name, content("b"))

      assert Datasets.activate(t.live, name, v1, :operator, operator()) == {:ok, :activated}

      assert {:ok, %Version{id: ^v1, version_no: 1, source: :operator}} =
               Datasets.active(t.live, name)

      assert Datasets.activate(t.live, name, v2, :operator, operator()) == {:ok, :activated}

      assert {:ok, %Version{id: ^v2, content: %{"rows" => [%{"code" => "b"}]}}} =
               Datasets.active(t.live, name)

      assert Datasets.active(t.test, name) == {:ok, nil}

      assert Datasets.activate(t.test, name, v1, :operator, operator()) ==
               {:ok, :version_not_found}
    end

    test "CH-18: a new version takes effect without a deploy and the old one stays readable", %{
      tenant: t
    } do
      name = define!(["tenant"])
      {:ok, {:published, v1, 1}} = publish(t.live, name, content("a", true))
      {:ok, :activated} = Datasets.activate(t.live, name, v1, :operator, operator())

      retry? = fn table -> hd(table["rows"])["retry"] end
      assert {:ok, {true, ref}} = Datasets.decide(t.live, name, retry?)

      {:ok, {:published, v2, 2}} = publish(t.live, name, content("a", false))
      {:ok, :activated} = Datasets.activate(t.live, name, v2, :operator, operator())
      assert {:ok, {false, ref2}} = Datasets.decide(t.live, name, retry?)

      assert ref["version_no"] == 1 and ref2["version_no"] == 2
      assert ref["version_id"] == Relay.ExternalId.encode("dsv", v1)
      assert ref["level"] == "tenant"
      assert Datasets.replay(t.live, ref, retry?) == {:ok, true}
      assert Datasets.replay(t.live, ref2, retry?) == {:ok, false}
    end

    test "OP-65: a decision without an active version is an error, never an empty table", %{
      tenant: t
    } do
      name = define!(["tenant"])

      assert {:error, %Relay.Error{code: :no_active_version}} =
               Datasets.decide(t.live, name, & &1)
    end

    test "OP-65: an installation-only data set cannot be published by a tenant", %{tenant: t} do
      name = define!(["installation"])
      assert {:ok, {:scope_not_allowed, nil, nil}} = publish(t.live, name, content("a"))
    end

    test "OP-65: an installation version is readable from a tenant's own transaction", %{
      tenant: t
    } do
      name = define!(["installation"])
      installation = Datasets.installation_scope()
      {:ok, {:published, v1, 1}} = publish(installation, name, content("a"))
      {:ok, :activated} = Datasets.activate(installation, name, v1, :operator, operator())

      assert {:ok, {:ok, %Version{id: ^v1}}} =
               Relay.Repo.in_scope(t.live, fn _status -> Datasets.active(installation, name) end)

      assert {:ok, {:error, %Relay.Error{code: :scope_mismatch}}} =
               Relay.Repo.in_scope(t.live, fn _status -> Datasets.active(t.test, name) end)

      assert {:ok, {_, %{"level" => "installation"}}} =
               Datasets.decide(installation, name, & &1)
    end
  end

  describe "OP-65 (3) audited activation and the node signal" do
    defp audit_rows(scope) do
      now = DateTime.utc_now()
      actor = TenantFixture.actor()

      {:ok, rows} =
        Relay.Repo.in_scope(scope, fn _status ->
          Relay.Repo.query!(
            "SELECT action, target_type, target_id, reason FROM relay_fn.audit_query($1, $2, NULL, NULL, 100, $3, $4, $5, $6, $7)",
            [
              DateTime.add(now, -3600),
              DateTime.add(now, 3600),
              TenantFixture.digest(),
              Atom.to_string(actor.kind),
              actor.ref,
              actor.on_behalf_of_ref,
              actor.access_record_ref
            ]
          ).rows
        end)

      Enum.filter(rows, fn [action | _] -> String.starts_with?(action, "dataset.") end)
    end

    defp subscribe!(scope, name) do
      {:ok, topic} =
        Relay.Platform.signal_topic(Relay.Scope.tenant_text(scope), "live", ["dataset", name])

      :ok = Relay.Platform.subscribe_signal(topic)
      await_up(topic)
      topic
    end

    defp await_up(topic, tries \\ 100) do
      case Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub) do
        %{^topic => :up} ->
          :ok

        _ when tries > 0 ->
          Process.sleep(50)
          await_up(topic, tries - 1)
      end
    end

    defp read_only(fun) do
      Relay.Repo.query!("SAVEPOINT relay_read_only_test", [])
      Relay.Repo.query!("SET LOCAL transaction_read_only = on", [])

      try do
        fun.()
      after
        Relay.Repo.query!("ROLLBACK TO SAVEPOINT relay_read_only_test", [])
      end
    end

    test "OP-65: publishing and activating a version each write an audit record", %{tenant: t} do
      name = define!(["tenant"])
      {:ok, {:published, v1, 1}} = publish(t.live, name, content("a"))
      {:ok, :activated} = Datasets.activate(t.live, name, v1, :operator, operator())
      id = Relay.Id.to_string(v1)

      assert [
               ["dataset.version_published", "dataset_version", ^id, nil],
               ["dataset.activated", "dataset_version", ^id, "operator"]
             ] = audit_rows(t.live)
    end

    test "OP-65: a committed activation signals every node to drop its cached version", %{
      tenant: t
    } do
      name = define!(["tenant"])
      {:ok, {:published, v1, 1}} = publish(t.live, name, content("a"))
      topic = subscribe!(t.live, name)

      {:ok, :activated} = Datasets.activate(t.live, name, v1, :operator, operator())
      assert_receive {:relay_signal, ^topic, {:seq, _}}, 5_000

      {:ok, :already_active} = Datasets.activate(t.live, name, v1, :operator, operator())
      refute_receive {:relay_signal, ^topic, {:seq, _}}, 1_500
    end

    test "OP-65: an activation that rolls back sends no signal and leaves no audit record", %{
      tenant: t
    } do
      name = define!(["tenant"])
      {:ok, {:published, v1, 1}} = publish(t.live, name, content("a"))
      topic = subscribe!(t.live, name)

      read_only(fn ->
        assert_raise Postgrex.Error, ~r/read-only transaction/, fn ->
          Datasets.activate(t.live, name, v1, :operator, operator())
        end
      end)

      refute_receive {:relay_signal, ^topic, {:seq, _}}, 1_500
      assert Datasets.active(t.live, name) == {:ok, nil}
      assert [["dataset.version_published", _, _, _]] = audit_rows(t.live)
    end
  end

  describe "OP-65 (5) bundled versions" do
    defp bundle!(dir, name, versions) do
      root = Path.join(dir, "datasets")
      File.mkdir_p!(Path.join(root, name))
      File.write!(Path.join([root, name, "schema.json"]), Jason.encode!(@schema))

      for {no, body} <- versions,
          do: File.write!(Path.join([root, name, "v#{no}.json"]), Jason.encode!(body))

      root
    end

    test "OP-65: an upgrade publishes and activates new bundled versions once", %{tmp_dir: dir} do
      name = define!(["installation"])
      root = bundle!(dir, name, [{1, content("a")}, {2, content("b")}])
      actor = TenantFixture.actor()

      assert {:ok, %{^name => %{published: [1, 2], activation: :activated}}} =
               Datasets.load_package(root, actor)

      assert {:ok, %Version{version_no: 2, source: :package}} =
               Datasets.active(Datasets.installation_scope(), name)

      assert {:ok, %{^name => %{published: [], activation: :unchanged}}} =
               Datasets.load_package(root, actor)

      root = bundle!(dir, name, [{1, content("a")}, {2, content("b")}, {3, content("c")}])

      assert {:ok, %{^name => %{published: [3], activation: :activated}}} =
               Datasets.load_package(root, actor)
    end

    test "OP-69: the bundled retention periods load into the installation scope" do
      assert {:ok, %{"retention_periods" => %{activation: activation}}} =
               Datasets.load_package(Package.root(), TenantFixture.actor())

      assert activation in [:activated, :unchanged, :operator_pinned]

      assert {:ok, %Version{content: %{"periods" => [_ | _]}}} =
               Datasets.active(Datasets.installation_scope(), "retention_periods")
    end

    test "OP-71: the newest bundled retention periods version is the active one" do
      assert {:ok, %{"retention_periods" => %{published: [1, 2], activation: activation}}} =
               Datasets.load_package(Package.root(), TenantFixture.actor())

      v2 = "priv/datasets/retention_periods/v2.json" |> File.read!() |> Jason.decode!()
      scope = Datasets.installation_scope()

      case activation do
        :activated ->
          assert {:ok, %Version{content: ^v2}} = Datasets.active(scope, "retention_periods")

        :operator_pinned ->
          assert {:ok, %Version{source: :operator}} = Datasets.active(scope, "retention_periods")
      end
    end

    test "OP-65: a bundled version never replaces an operator's version", %{tmp_dir: dir} do
      name = define!(["installation"])
      installation = Datasets.installation_scope()
      {:ok, {:published, own, 1}} = publish(installation, name, content("own"))
      {:ok, :activated} = Datasets.activate(installation, name, own, :operator, operator())

      root = bundle!(dir, name, [{1, content("a")}])

      assert {:ok, %{^name => %{published: [1], activation: :operator_pinned}}} =
               Datasets.load_package(root, TenantFixture.actor())

      assert {:ok, %Version{id: ^own, source: :operator}} = Datasets.active(installation, name)
    end

    test "OP-65: a bundled schema must equal the defined one and allow the installation", %{
      tmp_dir: dir
    } do
      changed = define!(["installation"], Map.put(@schema, "title", "older"))
      root = bundle!(dir, changed, [{1, content("a")}])

      assert {:error, %Relay.Error{code: :invalid_package}} =
               Datasets.load_package(root, TenantFixture.actor())

      tenant_only = define!(["tenant"])
      root = bundle!(Path.join(dir, "t"), tenant_only, [{1, content("a")}])

      assert {:error, %Relay.Error{code: :invalid_package}} =
               Datasets.load_package(root, TenantFixture.actor())
    end
  end
end
