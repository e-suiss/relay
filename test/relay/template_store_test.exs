defmodule Relay.TemplateStoreTest do
  use Relay.DataCase, async: false

  alias Relay.Actor
  alias Relay.Repo
  alias Relay.TemplateStore, as: Store
  alias RelayTest.TenantFixture

  @gate %{
    variables: %{"always" => [], "conditional" => []},
    measures: %{},
    findings: [],
    accept_warnings: false
  }

  setup do
    TenantFixture.as_role("relay_worker")
    %{scope: TenantFixture.tenant!().test, actor: TenantFixture.actor()}
  end

  defp category!(actor) do
    params =
      [Relay.Id.generate(), "orders", "Orders", "transactional", false, true, %{}] ++
        [nil, nil, nil, nil, false, TenantFixture.digest() | Actor.params(actor)]

    [%{"result" => "created"}] = Repo.call!("relay_fn.category_create", params)
    :ok
  end

  defp definition(body) do
    %{
      "default_locale" => "tr",
      "sensitivity" => "public",
      "cells" => %{"sms" => %{"tr" => %{"body" => body}}}
    }
  end

  defp template_flow(actor) do
    digest = TenantFixture.digest()
    at = %{key: "order.shipped", subtenant_id: nil, product: nil}
    category!(actor)

    attrs = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: at.key,
      name: "Order shipped",
      category: "orders",
      definition: definition("Kargoda")
    }

    {:created, template_id, _draft, 1} = Store.template_create(attrs, digest, actor)
    {:published, _, 1, 2} = Store.template_publish(at, @gate, nil, digest, actor)
    new = definition("Yolda")
    {:created, _, 3} = Store.template_draft_put(at, Relay.Id.generate(), new, 2, digest, actor)
    {:published, _, 2, 4} = Store.template_publish(at, @gate, 3, digest, actor)
    {:rolled_back, _, 5} = Store.template_rollback(at, 1, 4, digest, actor)
    producer = Map.put(at, :product, "access")

    %{
      template: Store.template(at.key, nil),
      versions: Enum.map(Store.template_versions(template_id), & &1["version_no"]),
      live: Store.template_live([at.key, "missing"], nil),
      protected: Store.template_archive(producer, nil, digest, actor)
    }
  end

  defp layout_flow(actor) do
    digest = TenantFixture.digest()
    at = %{key: "main", subtenant_id: nil}
    gate = %{findings: [], accept_warnings: false}

    attrs = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: "main",
      name: "Main",
      content: %{"mjml" => "<mjml/>"}
    }

    {:created, id, version_id, 1} = Store.asset_create(:layout, attrs, digest, actor)
    {:published, ^version_id, 1, 2} = Store.asset_publish(:layout, at, gate, 1, digest, actor)

    %{
      versions: Store.asset_versions(:layout, id),
      archive: Store.asset_archive(:layout, at, 2, digest, actor),
      row: Store.asset(:layout, "main", nil)
    }
  end

  describe "TP-48 TP-31 the template store" do
    test "TP-48, TP-31: a template is drafted, published, rolled back and read back", ctx do
      {:ok, result} = Store.in_scope(ctx.scope, fn _ -> template_flow(ctx.actor) end)

      assert %{"live_version_no" => 1, "category" => "orders"} = result.template
      assert result.template["template_type"] == "transactional"
      assert result.versions == [2, 1]
      assert [%{"version_no" => 1, "rule_id" => nil}, missing] = result.live
      assert missing["rule_id"] == "template.not_published"
      assert result.protected == {:protected, 5}
    end

    test "TP-35: a layout is created, published and archived through the store", ctx do
      {:ok, result} = Store.in_scope(ctx.scope, fn _ -> layout_flow(ctx.actor) end)

      assert [%{"version_no" => 1, "state" => "published"}] = result.versions
      assert result.archive == {:archived, 3}
      assert %{"state" => "archived", "live_version_no" => 1} = result.row
    end
  end
end
