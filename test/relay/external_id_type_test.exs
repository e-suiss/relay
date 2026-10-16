defmodule Relay.ExternalId.TypeTest do
  use ExUnit.Case, async: true

  alias Relay.ExternalId
  alias Relay.ExternalId.Type

  @id Relay.Id.build(0x017F22E279B0, <<0xCC3::12, 0x18C4DC0C0C07398F::62, 0::6>>)

  describe "API-9 the Ecto type checks the prefix of its field" do
    setup do
      %{params: Type.init(prefixes: ["rcp", "sub", "agt"])}
    end

    test "API-9: an identifier with one of the field's prefixes casts to its UUIDv7", %{
      params: params
    } do
      for prefix <- ["rcp", "sub", "agt"] do
        assert Type.cast(ExternalId.encode(prefix, @id), params) == {:ok, @id}
      end
    end

    test "API-9: another type's prefix, upper case or a raw UUID does not cast", %{params: params} do
      text = ExternalId.encode("sub", @id)

      for bad <- [ExternalId.encode("ntf", @id), String.upcase(text), Relay.Id.to_string(@id)] do
        assert {:error, _} = Type.cast(bad, params)
      end

      assert Type.cast(42, params) == :error
      assert Type.cast(nil, params) == {:ok, nil}
    end

    test "API-9: the stored form is the 16-byte UUIDv7", %{params: params} do
      assert Type.dump(@id, nil, params) == {:ok, @id}
      assert Type.dump(<<0::128>>, nil, params) == :error
      assert Type.load(@id, nil, params) == {:ok, @id}
    end

    test "T-58: an unknown prefix is a definition error" do
      assert_raise ArgumentError, fn -> Type.init(prefix: "xyz") end
      assert %{prefixes: ["stn"]} = Type.init(prefix: "stn")
    end
  end
end
