defmodule EsuissRelay.GeneratedTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Api
  alias EsuissRelay.Generated.Operations

  @contract File.read!("../../contracts/openapi/server.yaml")

  test "API-55: the SDK is pinned to the API version of the contract" do
    [version] =
      Regex.run(~r/^info:\n(?:  .*\n)*?  version: "([^"]+)"/m, @contract, capture: :all_but_first)

    assert EsuissRelay.api_version() == version
  end

  test "API-2: every generated operation has a function of the API module" do
    Code.ensure_loaded!(Api)
    operations = Operations.all()
    assert length(operations) > 200
    assert length(Enum.uniq_by(operations, & &1.id)) == length(operations)

    for operation <- operations do
      arity = 2 + length(operation.path_params) + if(operation.body == :required, do: 1, else: 0)
      assert function_exported?(Api, operation.id, arity), "#{operation.id}/#{arity}"
      assert String.starts_with?(operation.path, "/")
    end
  end

  test "API-56: the cursor lists are paginated and the mutations take an idempotency key" do
    assert %{paginated: true, method: :get} = Operations.fetch!(:list_waitpoints)
    assert %{idempotency: :required, body: :required} = Operations.fetch!(:create_waitpoint)
    assert %{idempotency: :required, body: :optional} = Operations.fetch!(:lease_mailbox_records)
    assert %{if_match: :required} = Operations.fetch!(:update_subscriber)
    assert %{content_type: "application/merge-patch+json"} = Operations.fetch!(:update_subscriber)
  end
end
