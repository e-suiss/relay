defmodule Relay.Access.FirstContactTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.FirstContact
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    :ok = Cache.forget(:_)
    :ok = FakeAccess.publish_first_contact!(nil)
    tenant = TenantFixture.tenant!()
    %{scope: tenant.test, access_tenant: tenant.attrs.access_tenant_id}
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp now_s, do: DateTime.to_unix(Relay.Clock.utc_now())

  defp read_directories do
    receive do
      {:fake_access, :first_contact_keys, slug} -> [slug | read_directories()]
    after
      0 -> []
    end
  end

  describe "E-103 first-contact token keys per Access environment" do
    test "E-103: each Access environment's directory is read under its own issuer and kept per issuer",
         ctx do
      :ok = FakeAccess.publish_first_contact!()
      key = FakeAccess.first_contact_key()
      slugs = [ctx.access_tenant <> "-a", ctx.access_tenant <> "-b"]

      assert {:ok, [a, b]} = FirstContact.issuers(ctx.scope)
      assert a == %{issuer_name: "access.test", origin: "localhost", token_keys: [key]}
      assert b == a
      assert Enum.sort(read_directories()) == slugs

      assert {:ok, [_a, _b]} = FirstContact.issuers(ctx.scope)
      assert read_directories() == []

      assert {:ok, [_a, _b]} = FirstContact.refresh(ctx.scope)
      assert Enum.sort(read_directories()) == slugs

      assert {:ok, [_a, _b]} = FirstContact.refresh(ctx.scope)
      assert read_directories() == []
    end

    test "E-103: a key is not used before its not-before, and a directory without keys keeps none",
         ctx do
      key = FakeAccess.first_contact_key()
      :ok = FakeAccess.publish_first_contact!([{key, now_s() + 3_600}])
      assert {:ok, [%{token_keys: []}, %{token_keys: []}]} = FirstContact.issuers(ctx.scope)

      :ok = FakeAccess.publish_first_contact!([{key, now_s() - 60}])

      assert {:ok, [%{token_keys: [^key]}, %{token_keys: [^key]}]} =
               FirstContact.issuers(ctx.scope)

      :ok = FakeAccess.publish_first_contact!(nil)
      assert {:ok, [%{token_keys: []}, %{token_keys: []}]} = FirstContact.issuers(ctx.scope)
    end

    test "E-103: only keys of type 2 with a valid not-before are listed, from their not-before on" do
      key = FakeAccess.first_contact_key()
      entry = %{"token-type" => 2, "token-key" => b64(key), "not-before" => 1_000}

      assert FirstContact.usable([entry], 1_000) == [key]
      assert FirstContact.usable([entry], 999) == []
      assert FirstContact.usable([Map.delete(entry, "not-before")], 0) == [key]

      for bad <- [
            %{entry | "token-type" => 1},
            %{entry | "not-before" => -1},
            %{entry | "not-before" => "1000"},
            %{entry | "token-key" => "not base64url!"},
            "not a key"
          ] do
        assert FirstContact.usable([bad], 2_000) == []
      end
    end

    test "AG-73: a tenant whose Access environments Access does not know has no issuer" do
      unknown = "tnt_unknown" <> FakeAccess.random()
      scope = TenantFixture.tenant!(access_tenant_id: unknown).test
      :ok = FakeAccess.publish_first_contact!()

      assert FirstContact.issuers(scope) == {:ok, []}
      assert read_directories() == []
    end
  end
end
