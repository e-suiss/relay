defmodule Relay.EmailReputationTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.EmailReputation
  alias RelayTest.TenantFixture

  @events ["email_reputation.warning", "email_reputation.stopped", "email_reputation.resumed"]

  defp forget do
    Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), "email_reputation"})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    %{scope: TenantFixture.tenant!().live}
  end

  defp published(scope) do
    {:ok, result} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.scoped_query!(
          "SELECT tenant_id, environment, event_type FROM relay.outbox_events WHERE event_type = ANY($1) ORDER BY created_at, id",
          [@events]
        )
      end)

    Enum.map(result.rows, &List.last/1)
  end

  describe "CH-41 CH-37 CH-87 the reputation circuit" do
    test "CH-87: a bounce rate at the warning threshold warns once and still sends", ctx do
      assert {:ok, :ok} = EmailReputation.count(ctx.scope, "mail.example.com", :sent, 100)
      assert {:ok, :warning} = EmailReputation.count(ctx.scope, "mail.example.com", :bounce, 3)
      assert {:ok, :warning} = EmailReputation.count(ctx.scope, "mail.example.com", :sent, 1)

      assert EmailReputation.admit(ctx.scope, "mail.example.com") == :allow
      assert published(ctx.scope) == ["email_reputation.warning"]
    end

    test "CH-87, CH-85: a stop needs the minimum volume and holds until it is closed", ctx do
      domain = "news.example.com"
      assert {:ok, :ok} = EmailReputation.count(ctx.scope, domain, :sent, 500)
      assert {:ok, :stopped} = EmailReputation.count(ctx.scope, domain, :bounce, 30)
      assert EmailReputation.admit(ctx.scope, domain) == :paused

      assert {:ok, :stopped} = EmailReputation.count(ctx.scope, domain, :sent, 5_000)
      assert EmailReputation.admit(ctx.scope, domain) == :paused

      actor = TenantFixture.actor()

      assert {:ok, %{"state" => "ok", "closed_at" => %DateTime{}}} =
               EmailReputation.close(ctx.scope, domain, "list cleaned", actor)

      assert EmailReputation.admit(ctx.scope, domain) == :allow

      assert {:error, :not_stopped} = EmailReputation.close(ctx.scope, domain, "again", actor)

      assert published(ctx.scope) == ["email_reputation.stopped", "email_reputation.resumed"]
    end

    test "CH-37: the complaint rate is over mail delivered to the inbox", ctx do
      domain = "shop.example.com"
      assert {:ok, :ok} = EmailReputation.count(ctx.scope, domain, :sent, 20_000)
      assert {:ok, :ok} = EmailReputation.count(ctx.scope, domain, :delivered, 10_000)
      assert {:ok, :warning} = EmailReputation.count(ctx.scope, domain, :complaint, 6)
    end

    test "CH-87: the domain of a sent delivery is remembered for its later events", ctx do
      id = Relay.Id.generate()
      assert :ok = EmailReputation.remember(ctx.scope, id, "mail.example.com")
      assert {:ok, "mail.example.com"} = EmailReputation.domain_of(ctx.scope, id)
      assert {:ok, nil} = EmailReputation.domain_of(ctx.scope, Relay.Id.generate())
    end
  end
end
