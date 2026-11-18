import type { Condition, Definition, Step } from "./model";

export type Operator =
  | "eq"
  | "ne"
  | "lt"
  | "lte"
  | "gt"
  | "gte"
  | "in"
  | "not_in"
  | "contains"
  | "starts_with"
  | "ends_with"
  | "exists"
  | "not_exists";

// WF-60
export const operators: readonly Operator[] = [
  "eq",
  "ne",
  "lt",
  "lte",
  "gt",
  "gte",
  "in",
  "not_in",
  "contains",
  "starts_with",
  "ends_with",
  "exists",
  "not_exists",
];

export type ValueKind = "string" | "number" | "boolean" | "null" | "list";
export const valueKinds: readonly ValueKind[] = [
  "string",
  "number",
  "boolean",
  "null",
  "list",
];

export interface Rule {
  path: string;
  operator: Operator;
  kind: ValueKind;
  value: string;
}

export interface RuleGroup {
  join: "all" | "any";
  rules: Rule[];
}

const binary = new Set<string>([
  "eq",
  "ne",
  "lt",
  "lte",
  "gt",
  "gte",
  "in",
  "not_in",
  "contains",
  "starts_with",
  "ends_with",
]);

export function emptyRule(path = ""): Rule {
  return { path, operator: "exists", kind: "string", value: "" };
}

function constant(rule: Rule): unknown {
  switch (rule.kind) {
    case "number":
      return Number(rule.value);
    case "boolean":
      return rule.value === "true";
    case "null":
      return null;
    case "list":
      return rule.value
        .split(",")
        .map((item) => item.trim())
        .filter((item) => item !== "");
    case "string":
      return rule.value;
  }
}

function ruleNode(rule: Rule): Condition {
  const variable = { var: rule.path };
  if (rule.operator === "exists") return { exists: variable };
  if (rule.operator === "not_exists") return { not: { exists: variable } };
  return { [rule.operator]: [variable, constant(rule)] };
}

// WF-60
// X-10
/** The condition a rule list builds: one rule alone, or every rule joined by `all` or `any`. */
export function toCondition(group: RuleGroup): Condition {
  const first = group.rules[0];
  if (group.rules.length === 1 && first !== undefined) return ruleNode(first);
  return { [group.join]: group.rules.map(ruleNode) };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function variablePath(value: unknown): string | null {
  if (!isRecord(value)) return null;
  const keys = Object.keys(value);
  const path = value.var;
  return keys.length === 1 && typeof path === "string" ? path : null;
}

function scalarKind(value: unknown): ValueKind | null {
  if (value === null) return "null";
  if (typeof value === "string") return "string";
  if (typeof value === "number") return "number";
  if (typeof value === "boolean") return "boolean";
  return null;
}

function ruleFrom(node: unknown): Rule | null {
  if (!isRecord(node)) return null;
  const entries = Object.entries(node);
  const entry = entries[0];
  if (entries.length !== 1 || entry === undefined) return null;
  const [operator, args] = entry;
  if (operator === "exists") {
    const path = variablePath(args);
    return path === null ? null : { ...emptyRule(path) };
  }
  if (operator === "not") {
    const inner = ruleFrom(args);
    return inner?.operator === "exists"
      ? { ...inner, operator: "not_exists" }
      : null;
  }
  if (!binary.has(operator) || !Array.isArray(args) || args.length !== 2)
    return null;
  const [left, right] = args as [unknown, unknown];
  const path = variablePath(left);
  if (path === null) return null;
  const base = { path, operator: operator as Operator };
  if (Array.isArray(right)) {
    if (!right.every((item) => typeof item === "string")) return null;
    return { ...base, kind: "list", value: right.join(", ") };
  }
  const kind = scalarKind(right);
  if (kind === null) return null;
  return {
    ...base,
    kind,
    value: right === null ? "" : String(right as string | number | boolean),
  };
}

// WF-60
// X-10
/** Reads a condition back into a rule list, or null when it has a shape the list cannot show (nested groups, `time_add`, a constant on the left). */
export function fromCondition(condition: Condition): RuleGroup | null {
  const single = ruleFrom(condition);
  if (single !== null) return { join: "all", rules: [single] };
  const entries = Object.entries(condition);
  const entry = entries[0];
  if (entries.length !== 1 || entry === undefined) return null;
  const [join, items] = entry;
  if ((join !== "all" && join !== "any") || !Array.isArray(items)) return null;
  const rules = (items as unknown[]).map(ruleFrom);
  if (rules.length === 0 || rules.some((rule) => rule === null)) return null;
  return { join, rules: rules.filter((rule): rule is Rule => rule !== null) };
}

export const pathPattern = /^(data|incoming)(\.[A-Za-z0-9_-]{1,128})+$/;

// WF-60
/** Whether a rule is complete: a readable path and, for a comparison, a value of its kind. */
export function ruleComplete(rule: Rule): boolean {
  if (rule.path === "") return false;
  if (rule.operator === "exists" || rule.operator === "not_exists") return true;
  if (rule.kind === "number")
    return rule.value.trim() !== "" && Number.isFinite(Number(rule.value));
  if (rule.kind === "boolean")
    return rule.value === "true" || rule.value === "false";
  if (rule.kind === "list") return rule.value.trim() !== "";
  return true;
}

export interface PathOption {
  path: string;
  group: "data" | "recipient" | "steps" | "time" | "incoming";
}

function schemaPaths(schema: unknown, prefix: string, level: number): string[] {
  if (!isRecord(schema) || level > 4) return [];
  const properties = schema.properties;
  if (!isRecord(properties)) return [];
  return Object.entries(properties).flatMap(([name, child]) => {
    const path = `${prefix}.${name}`;
    return [path, ...schemaPaths(child, path, level + 1)];
  });
}

const results: Record<string, readonly string[]> = {
  channel: ["delivered", "failed", "skipped", "seen", "read", "clicked"],
  throttle: ["throttled"],
  wait_for_event: ["matched", "timed_out"],
};

// WF-60
// X-10
/** The paths a condition may read from lists: the event data fields of the event schema, the declared recipient attributes, the results of the earlier steps on its path and the two timestamps. */
export function pathOptions(
  definition: Definition,
  earlier: readonly Step[],
): PathOption[] {
  return [
    ...schemaPaths(definition.event_schema, "data", 1).map(
      (path): PathOption => ({ path, group: "data" }),
    ),
    ...Object.keys(definition.recipient_attributes ?? {}).map(
      (name): PathOption => ({ path: `recipient.${name}`, group: "recipient" }),
    ),
    ...earlier.flatMap((step) =>
      (results[step.type] ?? []).map(
        (result): PathOption => ({
          path: `steps.${step.key}.${result}`,
          group: "steps",
        }),
      ),
    ),
    { path: "event.time", group: "time" },
    { path: "run.started_at", group: "time" },
  ];
}
