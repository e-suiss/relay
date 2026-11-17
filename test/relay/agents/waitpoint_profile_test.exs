defmodule Relay.Agents.WaitpointProfileTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  @describe "SELECT relay_fn.waitpoint_describe($1, $2, $3, $4, $5)"
  @profile "UPDATE relay.waitpoints SET profile = 'guardian_approval' WHERE id = $1"
  @label "UPDATE relay.waitpoints SET risk_tier = 'Not A Label' WHERE id = $1"
  @respond "SELECT * FROM relay_fn.waitpoint_respond($1, $2, $3, 'acc_1', 'acc_1', 'push', 'relay_session', NULL, $4, $5, $6, $7, NULL)"

  defp scenario do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder}
  end

  defp asking(ctx, opts \\ []) do
    defaults = [kind: "review", waiter_ref: ctx.agent, responder_ids: [ctx.responder]]
    ["opened", id, _, nil] = open(ctx.s, Keyword.merge(defaults, opts))
    id
  end

  defp event(ctx) do
    ["opened", id, _, nil] = open(ctx.s, kind: "event", waiter_ref: ctx.agent)
    id
  end

  defp described(id, fields) do
    one(@describe, [
      id,
      fields[:profile],
      fields[:outcome_class],
      fields[:risk_tier],
      fields[:correlation_id]
    ])
  end

  describe "AG-62 AG-8 profile and labels of a waitpoint" do
    setup do
      scenario()
    end

    test "AG-62: guardian_approval is written once, on a review without a default response",
         ctx do
      id = asking(ctx)

      assert described(id, profile: "guardian_approval") == "described"
      assert waitpoint(id, "profile") == "guardian_approval"
      assert described(id, profile: "guardian_approval") == "exists"

      with_default = asking(ctx, default_response_ct: "fallback")
      assert described(with_default, profile: "guardian_approval") == "profile_refused"
      assert waitpoint(with_default, "profile") == nil

      question = asking(ctx, kind: "question")
      assert described(question, profile: "guardian_approval") == "profile_refused"
      assert described(asking(ctx), profile: "another_profile") == "profile_refused"
      assert described(id(), profile: "guardian_approval") == "not_found"
    end

    test "AG-8: the owner's labels are stored as they came and an event waitpoint takes none",
         ctx do
      id = asking(ctx, kind: "question")
      fields = [outcome_class: "reversible", risk_tier: "tier:2", correlation_id: "corr-1"]

      assert described(id, fields) == "described"
      assert waitpoint(id, "outcome_class") == "reversible"
      assert waitpoint(id, "risk_tier") == "tier:2"
      assert waitpoint(id, "correlation_id") == "corr-1"
      assert waitpoint(id, "version") == 1

      assert described(event(ctx), risk_tier: "tier:2") == "labels_refused"
      assert described(event(ctx), correlation_id: "corr-2") == "described"
    end

    test "AG-62: a closed waitpoint is not described", ctx do
      id = asking(ctx)

      one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
        id,
        digest() | actor()
      ])

      assert described(id, profile: "guardian_approval") == "not_open"
    end
  end

  describe "AG-11 AG-53 constraints behind the functions" do
    defp prepared do
      ctx = scenario()
      review = asking(ctx)
      "described" = described(review, profile: "guardian_approval", risk_tier: "high")

      Map.merge(ctx, %{
        review: review,
        question: asking(ctx, kind: "question"),
        with_default: asking(ctx, default_response_ct: "fallback"),
        answered: asking(ctx),
        key: content_key!(ctx.s, ctx.responder)
      })
    end

    test "AG-11: the profile and the labels of a waitpoint never change" do
      as_owner(&prepared/0, fn ctx ->
        for sql <- [
              "UPDATE relay.waitpoints SET profile = NULL WHERE id = $1",
              "UPDATE relay.waitpoints SET risk_tier = 'low' WHERE id = $1"
            ] do
          assert sql_error(sql, [ctx.review]).postgres.message == "invariant_violation", sql
        end
      end)
    end

    test "AG-62: the database keeps guardian_approval to a review without a default response" do
      as_owner(&prepared/0, fn ctx ->
        for id <- [ctx.question, ctx.with_default] do
          assert sql_error(@profile, [id]).postgres.constraint == "waitpoints_profile_check"
        end

        assert sql_error(@label, [ctx.question]).postgres.constraint ==
                 "waitpoints_risk_tier_check"
      end)
    end

    test "AG-53: the database refuses a response value over the response size limit" do
      limit = Relay.Limits.fetch!(["waitpoint", "max_response_bytes"])
      assert limit == 65_536

      as_owner(&prepared/0, fn ctx ->
        subject = waitpoint(ctx.answered, "subject_digest")
        over = :binary.copy("v", limit + 30)
        params = [ctx.answered, id(), ctx.responder, subject, over, ctx.key, digest()]

        assert sql_error(@respond, params).postgres.constraint ==
                 "waitpoint_responses_value_ct_check"

        fits = List.replace_at(params, 4, :binary.copy("v", limit + 29))
        assert ["resolved", _response] = row(@respond, fits)
      end)
    end
  end
end
