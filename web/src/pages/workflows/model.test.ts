import { describe, expect, it } from "vitest";
import { tierSpans } from "../escalation/timeline";
import { cellsOf, locales, setCell } from "../templates/cells";
import {
  fromCondition,
  pathOptions,
  ruleComplete,
  toCondition,
  type RuleGroup,
} from "./condition";
import {
  allKeys,
  depth,
  earlierSteps,
  editable,
  getList,
  getStep,
  insertStep,
  moveStep,
  newStep,
  removeStep,
  stepIssues,
  stepTypes,
  type Definition,
  type Step,
} from "./model";

function tree(): Step[] {
  return [
    { type: "channel", key: "email_1", channel: "email", template: "welcome" },
    {
      type: "condition",
      key: "condition_1",
      branches: [
        {
          when: { eq: [{ var: "data.plan" }, "pro"] },
          steps: [{ type: "delay", key: "delay_1", duration: "PT1H" }],
        },
      ],
      else: [],
    },
    {
      type: "throttle",
      key: "throttle_1",
      throttle_key: "x",
      limit: 1,
      window: "PT1H",
    },
  ];
}

describe("X-10 workflow editor tree", () => {
  it("offers exactly the eight steps of the definition schema", () => {
    expect(stepTypes).toEqual([
      "channel",
      "delay",
      "digest",
      "throttle",
      "condition",
      "wait_for_event",
      "time_window",
      "webhook",
    ]);
    for (const type of stepTypes) {
      const step = newStep(type, ["channel_1"]);
      expect(step.type).toBe(type);
      expect(step.key).toMatch(/^[a-z][a-z0-9_]{0,63}$/);
    }
    expect(newStep("channel", ["channel_1"]).key).toBe("channel_2");
  });

  it("addresses lists and steps by JSON pointer", () => {
    const steps = tree();
    expect(getList(steps, "/steps/1/branches/0/steps")?.[0]?.key).toBe(
      "delay_1",
    );
    expect(getStep(steps, "/steps/1/branches/0/steps/0")?.key).toBe("delay_1");
    expect(getList(steps, "/steps/1/else")).toEqual([]);
    expect(getList(steps, "/steps/0/else")).toBeNull();
    expect(allKeys(steps)).toEqual([
      "email_1",
      "condition_1",
      "delay_1",
      "throttle_1",
    ]);
    expect(depth(steps)).toBe(1);
  });

  it("inserts, removes and moves steps, never into their own branches", () => {
    const steps = tree();
    const added = insertStep(
      steps,
      "/steps/1/else",
      0,
      newStep("webhook", allKeys(steps)),
    );
    expect(getStep(added, "/steps/1/else/0")?.type).toBe("webhook");
    expect(removeStep(added, "/steps/0")).toHaveLength(2);
    const down = moveStep(steps, "/steps/0", "/steps", 3);
    expect(down?.map((step) => step.key)).toEqual([
      "condition_1",
      "throttle_1",
      "email_1",
    ]);
    const up = moveStep(steps, "/steps/2", "/steps", 0);
    expect(up?.[0]?.key).toBe("throttle_1");
    const into = moveStep(steps, "/steps/0", "/steps/1/else", 0);
    expect(getStep(into ?? [], "/steps/0/else/0")?.key).toBe("email_1");
    const out = moveStep(steps, "/steps/1/branches/0/steps/0", "/steps", 3);
    expect(out?.at(-1)?.key).toBe("delay_1");
    expect(moveStep(steps, "/steps/1", "/steps/1/else", 0)).toBeNull();
  });

  it("marks missing and malformed fields before the gate runs", () => {
    expect(stepIssues(newStep("channel", []))).toEqual([
      { field: "template", code: "required" },
    ]);
    expect(
      stepIssues({ type: "delay", key: "Bad Key", duration: "2h" }).map(
        (issue) => issue.field,
      ),
    ).toEqual(["key", "duration"]);
  });

  it("lists the earlier steps on a step's own path", () => {
    expect(
      earlierSteps(tree(), "/steps/1/branches/0/steps/0").map(
        (step) => step.key,
      ),
    ).toEqual(["email_1"]);
    expect(earlierSteps(tree(), "/steps/2").map((step) => step.key)).toEqual([
      "email_1",
      "condition_1",
    ]);
  });
});

describe("X-9 single manager", () => {
  it("lets a code-managed workflow change only its marked control fields", () => {
    expect(editable("panel", [], "/steps/0/template")).toBe(true);
    expect(editable("code", ["/steps/0/template"], "/steps/0/template")).toBe(
      true,
    );
    expect(editable("code", ["/steps/0/template"], "/steps/0/channel")).toBe(
      false,
    );
  });
});

describe("WF-60 conditions from lists", () => {
  it("round-trips the rule lists the builder shows", () => {
    const group: RuleGroup = {
      join: "any",
      rules: [
        { path: "data.total", operator: "gte", kind: "number", value: "100" },
        {
          path: "data.tier",
          operator: "in",
          kind: "list",
          value: "gold, silver",
        },
        {
          path: "steps.email_1.clicked",
          operator: "eq",
          kind: "boolean",
          value: "true",
        },
        {
          path: "recipient.vip",
          operator: "not_exists",
          kind: "string",
          value: "",
        },
      ],
    };
    const condition = toCondition(group);
    expect(condition).toEqual({
      any: [
        { gte: [{ var: "data.total" }, 100] },
        { in: [{ var: "data.tier" }, ["gold", "silver"]] },
        { eq: [{ var: "steps.email_1.clicked" }, true] },
        { not: { exists: { var: "recipient.vip" } } },
      ],
    });
    expect(fromCondition(condition)).toEqual({
      ...group,
      rules: group.rules.map((rule) =>
        rule.kind === "list" ? { ...rule, value: "gold, silver" } : rule,
      ),
    });
  });

  it("keeps a condition the lists cannot show untouched", () => {
    expect(
      fromCondition({ all: [{ any: [{ exists: { var: "data.a" } }] }] }),
    ).toBeNull();
    expect(
      fromCondition({
        lt: [
          { var: "event.time" },
          { time_add: [{ var: "run.started_at" }, "PT1H"] },
        ],
      }),
    ).toBeNull();
  });

  it("offers schema fields, attributes, earlier results and timestamps", () => {
    const definition: Definition = {
      name: "x",
      category: "c",
      event_schema: {
        type: "object",
        properties: {
          order: { type: "object", properties: { total: { type: "number" } } },
        },
      },
      recipient_attributes: { vip: "boolean" },
      steps: [],
    };
    const paths = pathOptions(definition, [newStep("channel", [])]).map(
      (option) => option.path,
    );
    expect(paths).toContain("data.order");
    expect(paths).toContain("data.order.total");
    expect(paths).toContain("recipient.vip");
    expect(paths).toContain("steps.channel_1.clicked");
    expect(paths).toContain("event.time");
    expect(
      ruleComplete({
        path: "data.a",
        operator: "gt",
        kind: "number",
        value: "x",
      }),
    ).toBe(false);
  });
});

describe("AG-17 escalation timeline", () => {
  it("opens each tier and repeat after the previous one", () => {
    expect(
      tierSpans([{ after: "PT2H", repeat: 1 }, { after: "PT6H" }])?.map(
        (span) => span.opensAt,
      ),
    ).toEqual([7200, 14400, 36000]);
    expect(tierSpans([{ after: "2h" }])).toBeNull();
  });
});

describe("TP-10 channel × locale matrix", () => {
  it("writes and removes one cell without touching the others", () => {
    const cells = setCell({}, "sms", "tr-TR", { body: "Merhaba" });
    const both = setCell(cells, "sms", "en-GB", { body: "Hello" });
    expect(Object.keys(cellsOf(both, "sms"))).toEqual(["tr-TR", "en-GB"]);
    expect(locales("tr-TR", both)).toEqual(["tr-TR", "en-GB"]);
    expect(setCell(cells, "sms", "tr-TR", null)).toEqual({});
  });
});
