defmodule Relay.SubscriberToken.KeyRotationTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Access.SubscriberTokenKeys
  alias RelayTest.Api
  alias RelayTest.Dpop
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture
  alias RelayWeb.Auth.Subscriber

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"
  @url "https://relay.test/v1/subscriber/token"
  @cache {SubscriberTokenKeys, :snapshot}
  @retired "SELECT state, retired_reason, retired_by FROM relay.subscriber_token_keys WHERE label = $1"

  setup do
    :ok = FakeAccess.install!()
    Relay.Access.Cache.delete(@cache)
    on_exit(fn -> Relay.Access.Cache.delete(@cache) end)
    tenant = TenantFixture.tenant!()
    app = FakeAccess.client!(tenant.test, ["read"])
    %{access_tenant: tenant.attrs.access_tenant_id, app: app}
  end

  defp token(ctx) do
    sub = "pairwise-" <> FakeAccess.random()
    subject = FakeAccess.user_token(ctx.access_tenant, ctx.app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => subject,
      "subject_token_type" => @subject_type
    }

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"dpop", Dpop.proof(:post, @url, subject)}
    ]

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    Jason.decode!(conn.resp_body)["access_token"]
  end

  defp kid(token) do
    [header | _] = String.split(token, ".")
    header |> Base.url_decode64!(padding: false) |> Jason.decode!() |> Map.fetch!("kid")
  end

  describe "IN-51 subscriber token key rotation" do
    test "IN-51: the configured key is current and its label is the kid", ctx do
      assert {:ok, %{current: %{label: "subscriber-token", activated_at: %DateTime{}}}} =
               SubscriberTokenKeys.snapshot(fresh: true)

      token = token(ctx)
      assert kid(token) == "subscriber-token"
      assert {:ok, %{kid: "subscriber-token"}} = Subscriber.verify(token)
    end

    test "IN-51: after a rotation the new key signs and the previous key verifies for two token lifetimes",
         ctx do
      old = token(ctx)

      assert {:ok, rotated} =
               SubscriberTokenKeys.rotate("subscriber-token-2", "operator-1", "scheduled")

      assert rotated.current == "subscriber-token-2"
      assert rotated.previous == "subscriber-token"
      window = DateTime.diff(rotated.previous_verify_until, DateTime.utc_now())
      assert window > SubscriberTokenKeys.window_s() - 60
      assert window <= SubscriberTokenKeys.window_s()
      assert SubscriberTokenKeys.window_s() == 2 * Relay.Access.SubscriberToken.lifetime_s()

      new = token(ctx)
      assert kid(new) == "subscriber-token-2"
      assert {:ok, %{kid: "subscriber-token-2"}} = Subscriber.verify(new)
      assert {:ok, %{kid: "subscriber-token"}} = Subscriber.verify(old)

      assert {:error, %Relay.Error{code: :key_exists}} =
               SubscriberTokenKeys.rotate("subscriber-token", "operator-1", "back")
    end

    test "IN-51, IN-33: an emergency retirement stops the previous key at once and is kept", ctx do
      old = token(ctx)
      {:ok, _} = SubscriberTokenKeys.rotate("subscriber-token-3", "operator-1", "compromise")

      assert {:ok, %{retired: "subscriber-token"}} =
               SubscriberTokenKeys.retire_previous("operator-1", "suspected compromise")

      assert {:ok, false} = SubscriberTokenKeys.accepted?("subscriber-token", fresh: true)
      assert {:error, %Relay.Error{code: :auth_invalid_token}} = Subscriber.verify(old)
      assert {:ok, %{kid: "subscriber-token-3"}} = Subscriber.verify(token(ctx))

      assert {:error, %Relay.Error{code: :not_found}} =
               SubscriberTokenKeys.retire_previous("operator-1", "again")

      assert {:ok, %{rows: [["retired", "compromise", "operator-1"]]}} =
               Relay.Repo.unscoped_query(:subscriber_token_keys, @retired, ["subscriber-token"])
    end

    test "IN-51: the previous key verifies only inside its window, an unknown key never" do
      now = DateTime.utc_now()

      snapshot = %{
        current: %{label: "b", activated_at: now},
        previous: %{label: "a", verify_until: DateTime.add(now, 60, :second)}
      }

      assert SubscriberTokenKeys.accepts?(snapshot, "b", now)
      assert SubscriberTokenKeys.accepts?(snapshot, "a", now)
      refute SubscriberTokenKeys.accepts?(snapshot, "a", DateTime.add(now, 60, :second))
      refute SubscriberTokenKeys.accepts?(%{snapshot | previous: nil}, "a", now)
      refute SubscriberTokenKeys.accepts?(snapshot, "c", now)
    end

    test "IN-51: rotation is due after 90 days and the activation is an alarm metric" do
      assert SubscriberTokenKeys.rotation_days() == 90
      assert {:ok, status} = SubscriberTokenKeys.status()
      assert status.current == "subscriber-token"
      assert DateTime.diff(status.rotation_due_at, status.activated_at, :day) == 90

      assert Enum.any?(
               RelayWeb.Telemetry.alarm_metrics(),
               &(&1.event_name == [:relay, :access, :subscriber_token_key])
             )
    end
  end
end
