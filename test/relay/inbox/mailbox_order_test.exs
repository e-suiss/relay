defmodule Relay.Inbox.MailboxOrderTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Inbox.Mailbox
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @writers 20
  @per_writer 500

  defp committed_mailbox do
    Sandbox.unboxed_run(Repo, fn ->
      tenant = TenantFixture.tenant!()
      owner = TenantFixture.recipient!(tenant.live, %{})
      {:ok, {:created, mailbox, _stream}} = Mailbox.ensure(tenant.live, :subscriber, owner)
      %{scope: tenant.live, mailbox: mailbox}
    end)
  end

  defp record(mailbox) do
    %{
      id: Relay.Id.generate(),
      mailbox_id: mailbox,
      kind: :message,
      event_type: "inbox.message",
      payload_digest: :crypto.strong_rand_bytes(32)
    }
  end

  defp read_all(scope, mailbox, since \\ 0, acc \\ []) do
    {:ok, page} = Mailbox.read(scope, mailbox, 1, since, Mailbox.replay_cap())
    acc = acc ++ page.records

    if page.has_more,
      do: read_all(scope, mailbox, List.last(page.records).seq, acc),
      else: {page, acc}
  end

  describe "C-71 OP-5 AG-24 commit order under concurrent writers" do
    @tag timeout: 300_000
    test "C-71: 20 concurrent writers of 500 records each leave a gapless sequence in commit order" do
      %{scope: scope, mailbox: mailbox} = committed_mailbox()

      appended =
        1..@writers
        |> Task.async_stream(
          fn _writer ->
            for _ <- 1..@per_writer do
              {:ok, {:appended, 1, seq}} =
                Sandbox.unboxed_run(Repo, fn ->
                  Mailbox.append(scope, record(mailbox))
                end)

              seq
            end
          end,
          max_concurrency: @writers,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, seqs} -> seqs end)

      for seqs <- appended, do: assert(seqs == Enum.sort(seqs))

      total = @writers * @per_writer
      assert appended |> List.flatten() |> Enum.sort() == Enum.to_list(1..total)

      {last, records} = Sandbox.unboxed_run(Repo, fn -> read_all(scope, mailbox) end)
      assert Enum.map(records, & &1.seq) == Enum.to_list(1..total)
      assert last.head_seq == total
      refute last.has_more
    end
  end

  describe "IN-22 IN-29 since reads page by the replay cap" do
    setup do
      TenantFixture.as_role("relay_worker")
      tenant = TenantFixture.tenant!()
      owner = TenantFixture.recipient!(tenant.live, %{})
      {:ok, {:created, mailbox, _}} = Mailbox.ensure(tenant.live, :subscriber, owner)
      %{scope: tenant.live, mailbox: mailbox}
    end

    test "IN-29: a page says whether more follow and whether the gap is beyond the replay cap",
         ctx do
      for n <- 1..3,
          do: {:ok, {:appended, 1, ^n}} = Mailbox.append(ctx.scope, record(ctx.mailbox))

      assert {:ok, %{records: [%{seq: 1}, %{seq: 2}], has_more: true, truncated: false}} =
               Mailbox.read(ctx.scope, ctx.mailbox, 1, 0, 2)

      assert {:ok, %{records: [%{seq: 3}], has_more: false, head_seq: 3}} =
               Mailbox.read(ctx.scope, ctx.mailbox, 1, 2, 2)

      assert {:resync_required, %{epoch: 1, head_seq: 3}} =
               Mailbox.read(ctx.scope, ctx.mailbox, 1, 4)

      assert :not_found = Mailbox.read(ctx.scope, Relay.Id.generate(), 1, 0)
    end

    test "IN-29: more than the replay cap behind marks the page truncated", ctx do
      for _ <- 1..(Mailbox.replay_cap() + 1),
          do: {:ok, {:appended, _, _}} = Mailbox.append(ctx.scope, record(ctx.mailbox))

      assert {:ok, %{truncated: true, has_more: true, records: records}} =
               Mailbox.read(ctx.scope, ctx.mailbox, 1, 0)

      assert length(records) == Mailbox.replay_cap()
      assert {:ok, %{truncated: false}} = Mailbox.read(ctx.scope, ctx.mailbox, 1, 1)
    end

    test "AG-21: a lease and its acknowledgement through the core", ctx do
      {:ok, {:appended, _, _}} = Mailbox.append(ctx.scope, record(ctx.mailbox))

      assert {:ok, [%{id: id, delivery_count: 1}]} =
               Mailbox.lease(ctx.scope, ctx.mailbox, "worker-a", 10,
                 lease_ms: 60_000,
                 max_deliveries: 5
               )

      assert {:ok, [{^id, :acked}]} = Mailbox.ack(ctx.scope, ctx.mailbox, [id], "worker-a")
      assert {:ok, :advanced} = Mailbox.advance_cursor(ctx.scope, ctx.mailbox, "web", 1, 1)
    end
  end
end
