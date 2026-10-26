defmodule Relay.Agents.WaitpointErasureTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp erase(recipient),
    do:
      row(
        "SELECT * FROM relay_fn.subject_erase($1, 'dsr_1', ARRAY['recipient_profile'], ARRAY[]::text[], $2, $3, $4, $5, $6)",
        [recipient, digest() | actor()]
      )

  defp question(ctx, opts \\ []) do
    ["opened", id, _, nil] =
      open(
        ctx.s,
        Keyword.merge(
          [
            waiter_ref: ctx.agent,
            responder_ids: [ctx.responder],
            default_response_ct: "fallback",
            claim_text_ct: "claim"
          ],
          opts
        )
      )

    id
  end

  describe "OP-24 C-86 AG-5 erasure reaches waitpoints and mailboxes" do
    test "OP-24: erasing a responder cancels its open waitpoints and drops their texts", ctx do
      open_one = question(ctx)
      closed = question(ctx)

      one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
        closed,
        digest() | actor()
      ])

      assert ["erased", _] = erase(ctx.responder)

      assert row(
               "SELECT state, cancel_reason, content_ct, claim_text_ct, default_response_ct, field_key_id FROM relay.waitpoints WHERE id = $1",
               [open_one]
             ) == ["cancelled", "subject_erasure", nil, nil, nil, nil]

      assert row(
               "SELECT state, cancel_reason, content_ct, fields_erased_at IS NOT NULL FROM relay.waitpoints WHERE id = $1",
               [closed]
             ) == ["cancelled", "done", nil, true]

      assert List.last(mailbox_events(waitpoint(open_one, "waiter_mailbox_id"))) ==
               "waitpoint.cancelled"

      assert one("SELECT open_count FROM relay.waitpoint_counters") == 0
    end

    test "AG-5: erasing an agent deletes its mailbox and cancels the waitpoints it waits on",
         ctx do
      id = question(ctx)
      mailbox = waitpoint(id, "waiter_mailbox_id")

      assert ["erased", _] = erase(ctx.agent)
      assert waitpoint(id, "state") == "cancelled"

      assert row("SELECT state, deleted_reason FROM relay.mailboxes WHERE id = $1", [mailbox]) ==
               ["deleted", "erasure"]

      assert ["mailbox_inactive", nil, nil] = append(mailbox)
    end

    test "C-86: erasure leaves other subjects' waitpoints and API client mailboxes alone", ctx do
      other = member!(ctx.s, "subscriber")
      kept = question(ctx, responder_ids: [other])
      client = id()

      ["opened", api_waitpoint, _, nil] =
        open(ctx.s, kind: "event", waiter_kind: "api_client", waiter_ref: client)

      assert ["erased", _] = erase(ctx.responder)
      assert waitpoint(kept, "state") == "open"
      assert waitpoint(kept, "content_ct") == "content"
      assert waitpoint(api_waitpoint, "state") == "open"
    end
  end
end
