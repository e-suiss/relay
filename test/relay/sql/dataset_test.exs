defmodule Relay.Sql.DatasetTest do
  use Relay.SqlCase, async: true

  alias Relay.Repo

  @publish "SELECT * FROM relay_fn.dataset_version_publish($1, $2, $3, $4, $5, 'pkg@1', now(), $6, $7, $8, $9, $10)"
  @activate "SELECT relay_fn.dataset_activate($1, $2, $3, $4, $5, $6, $7, $8)"

  defp dataset!(scopes) do
    name = "sqltest_" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(6)))

    Repo.query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, '{}', $2, $3, now())",
      [name, digest(), scopes]
    )

    name
  end

  defp publish(name, content, source) do
    row(@publish, [
      id(),
      name,
      content,
      :crypto.hash(:sha256, :erlang.term_to_binary(content)),
      source,
      digest() | actor()
    ])
  end

  setup do
    tenant_only = dataset!(["tenant"])
    installation_only = dataset!(["installation"])
    tenant = tenant!()
    ctx(tenant)
    %{tenant_only: tenant_only, installation_only: installation_only}
  end

  test "OP-8: dataset versions are immutable, numbered and published once per content", %{
    tenant_only: name
  } do
    assert ["published", v1, 1] = publish(name, %{"v" => 1}, "operator")
    assert publish(name, %{"v" => 1}, "operator") == ["exists", v1, 1]
    assert ["published", _v2, 2] = publish(name, %{"v" => 2}, "package")
    assert publish("no_such_dataset", %{}, "package") == ["dataset_not_found", nil, nil]

    assert error_message("UPDATE relay.dataset_versions SET source_ref = 'x' WHERE id = $1", [v1]) =~
             "permission denied"
  end

  test "OP-8: a package activation never replaces an operator-pinned version", %{
    tenant_only: name
  } do
    ["published", operator, 1] = publish(name, %{"v" => 1}, "operator")
    ["published", package, 2] = publish(name, %{"v" => 2}, "package")

    assert one(@activate, [name, operator, "operator", digest() | actor()]) == "activated"
    assert one(@activate, [name, operator, "operator", digest() | actor()]) == "already_active"
    assert one(@activate, [name, package, "package", digest() | actor()]) == "operator_pinned"
    assert one(@activate, [name, package, "operator", digest() | actor()]) == "activated"
    assert one(@activate, [name, id(), "operator", digest() | actor()]) == "version_not_found"
  end

  test "OP-8: an installation-only dataset cannot be published by a tenant", %{
    installation_only: name
  } do
    assert publish(name, %{}, "package") == ["scope_not_allowed", nil, nil]
  end
end
