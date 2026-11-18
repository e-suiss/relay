import type { Channel } from "../../api/types";
import { isDuration } from "../../lib/duration";

export type StepType =
  | "channel"
  | "delay"
  | "digest"
  | "throttle"
  | "condition"
  | "wait_for_event"
  | "time_window"
  | "webhook";

// X-10
export const stepTypes: readonly StepType[] = [
  "channel",
  "delay",
  "digest",
  "throttle",
  "condition",
  "wait_for_event",
  "time_window",
  "webhook",
];

export const channels: readonly Channel[] = [
  "email",
  "sms",
  "push",
  "web_push",
  "in_app",
  "whatsapp",
  "voice",
  "slack",
  "teams",
  "telegram",
  "discord",
  "webhook",
];

export type Weekday = "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
export const weekdays: readonly Weekday[] = [
  "mon",
  "tue",
  "wed",
  "thu",
  "fri",
  "sat",
  "sun",
];

export type Condition = Record<string, unknown>;
export type RouteNode = string | Record<string, unknown>;

export interface Variant {
  key: string;
  weight: number;
  template: string;
}

export interface ChannelStep {
  type: "channel";
  key: string;
  channel?: Channel;
  route?: RouteNode;
  template: string;
  digest_template?: string;
  variants?: Variant[];
  overrides?: Record<string, unknown>;
  timing?: "immediate" | "next_break";
  max_defer?: string;
}

export interface DelayStep {
  type: "delay";
  key: string;
  duration?: string;
  until?: string;
}

export interface DigestStep {
  type: "digest";
  key: string;
  digest_key: string;
  mode: "fixed" | "sliding" | "scheduled";
  debounce?: string;
  max_wait?: string;
  schedule?: string;
  max_items?: number;
  leading?: "immediate" | "none";
  render?: { first?: number; last?: number };
}

export interface ThrottleStep {
  type: "throttle";
  key: string;
  throttle_key: string;
  limit: number;
  window?: string;
  until?: string;
  calendar?: "day" | "week";
}

export interface Branch {
  when: Condition;
  steps: Step[];
}

export interface ConditionStep {
  type: "condition";
  key: string;
  branches: Branch[];
  else?: Step[];
}

export interface WaitStep {
  type: "wait_for_event";
  key: string;
  event_type: string;
  correlation_key: string;
  match?: Condition;
  timeout: string;
  on_timeout?: Step[];
}

export interface TimeWindow {
  days: Weekday[];
  start: string;
  end: string;
}

export interface TimeWindowStep {
  type: "time_window";
  key: string;
  windows: TimeWindow[];
}

export interface WebhookStep {
  type: "webhook";
  key: string;
  endpoint: string;
  event_type: string;
}

export type Step =
  | ChannelStep
  | DelayStep
  | DigestStep
  | ThrottleStep
  | ConditionStep
  | WaitStep
  | TimeWindowStep
  | WebhookStep;

export interface Definition {
  name: string;
  description?: string;
  category: string;
  message_class?: string;
  security_subtype?: string;
  event_schema: Record<string, unknown>;
  recipient_attributes?: Record<string, string>;
  steps: Step[];
  overrides?: Record<string, unknown>;
  content_dedup?: { window: string };
  controls?: string[];
}

export const rootList = "/steps";

function decode(token: string): string {
  return token.replace(/~1/g, "/").replace(/~0/g, "~");
}

function tokens(pointer: string): string[] {
  return pointer.split("/").slice(1).map(decode);
}

/** The child step lists of a step with their pointers relative to the step. */
export function childLists(step: Step): { slot: string; steps: Step[] }[] {
  if (step.type === "condition")
    return [
      ...step.branches.map((branch, index) => ({
        slot: `/branches/${index}/steps`,
        steps: branch.steps,
      })),
      ...(step.else === undefined ? [] : [{ slot: "/else", steps: step.else }]),
    ];
  if (step.type === "wait_for_event" && step.on_timeout !== undefined)
    return [{ slot: "/on_timeout", steps: step.on_timeout }];
  return [];
}

function childList(step: Step, rest: string[]): Step[] | null {
  if (step.type === "condition") {
    if (rest[0] === "else" && rest.length === 1) return step.else ?? null;
    if (rest[0] === "branches" && rest[2] === "steps" && rest.length === 3)
      return step.branches[Number(rest[1])]?.steps ?? null;
  }
  if (
    step.type === "wait_for_event" &&
    rest[0] === "on_timeout" &&
    rest.length === 1
  )
    return step.on_timeout ?? null;
  return null;
}

function withChildList(step: Step, rest: string[], list: Step[]): Step {
  if (step.type === "condition") {
    if (rest[0] === "else") return { ...step, else: list };
    const index = Number(rest[1]);
    return {
      ...step,
      branches: step.branches.map((branch, at) =>
        at === index ? { ...branch, steps: list } : branch,
      ),
    };
  }
  if (step.type === "wait_for_event") return { ...step, on_timeout: list };
  return step;
}

function split(listPointer: string): string[] | null {
  const parts = tokens(listPointer);
  return parts[0] === "steps" ? parts.slice(1) : null;
}

function listAt(steps: Step[], rest: string[]): Step[] | null {
  if (rest.length === 0) return steps;
  const head = rest[0];
  if (head === undefined) return null;
  const step = steps[Number(head)];
  if (step === undefined) return null;
  const slotLength = rest[1] === "branches" ? 3 : 1;
  const own = childList(step, rest.slice(1, 1 + slotLength));
  if (own === null) return null;
  return listAt(own, rest.slice(1 + slotLength));
}

/** The step list at a list pointer such as `/steps` or `/steps/2/branches/0/steps`. */
export function getList(steps: Step[], listPointer: string): Step[] | null {
  const rest = split(listPointer);
  return rest === null ? null : listAt(steps, rest);
}

function mapListAt(
  steps: Step[],
  rest: string[],
  change: (list: Step[]) => Step[],
): Step[] {
  if (rest.length === 0) return change(steps);
  const index = Number(rest[0]);
  const step = steps[index];
  if (step === undefined) return steps;
  const slotLength = rest[1] === "branches" ? 3 : 1;
  const slot = rest.slice(1, 1 + slotLength);
  const own = childList(step, slot);
  if (own === null) return steps;
  const next = withChildList(
    step,
    slot,
    mapListAt(own, rest.slice(1 + slotLength), change),
  );
  return steps.map((item, at) => (at === index ? next : item));
}

/** Changes the step list at a list pointer and returns the new tree. */
export function updateList(
  steps: Step[],
  listPointer: string,
  change: (list: Step[]) => Step[],
): Step[] {
  const rest = split(listPointer);
  return rest === null ? steps : mapListAt(steps, rest, change);
}

/** The list pointer and index of a step pointer such as `/steps/1`. */
export function parent(stepPointer: string): { list: string; index: number } {
  const cut = stepPointer.lastIndexOf("/");
  return {
    list: stepPointer.slice(0, cut),
    index: Number(stepPointer.slice(cut + 1)),
  };
}

export function getStep(steps: Step[], stepPointer: string): Step | null {
  const { list, index } = parent(stepPointer);
  return getList(steps, list)?.[index] ?? null;
}

export function insertStep(
  steps: Step[],
  listPointer: string,
  index: number,
  step: Step,
): Step[] {
  return updateList(steps, listPointer, (list) => [
    ...list.slice(0, index),
    step,
    ...list.slice(index),
  ]);
}

export function removeStep(steps: Step[], stepPointer: string): Step[] {
  const { list, index } = parent(stepPointer);
  return updateList(steps, list, (items) =>
    items.filter((_item, at) => at !== index),
  );
}

export function replaceStep(
  steps: Step[],
  stepPointer: string,
  step: Step,
): Step[] {
  const { list, index } = parent(stepPointer);
  return updateList(steps, list, (items) =>
    items.map((item, at) => (at === index ? step : item)),
  );
}

/** Moves a step to a list and index; a step never moves into its own branches. Returns null when the move is not possible. */
export function moveStep(
  steps: Step[],
  from: string,
  toList: string,
  toIndex: number,
): Step[] | null {
  if (toList === from || toList.startsWith(`${from}/`)) return null;
  const step = getStep(steps, from);
  if (step === null || getList(steps, toList) === null) return null;
  const source = parent(from);
  let index = toIndex;
  if (source.list === toList) {
    if (toIndex === source.index || toIndex === source.index + 1) return steps;
    if (toIndex > source.index) index -= 1;
    return updateList(steps, toList, (list) => {
      const without = list.filter((_item, at) => at !== source.index);
      return [...without.slice(0, index), step, ...without.slice(index)];
    });
  }
  const adjusted = adjustAfterRemoval(toList, source);
  return insertStep(removeStep(steps, from), adjusted, index, step);
}

function adjustAfterRemoval(
  listPointer: string,
  removed: { list: string; index: number },
): string {
  const prefix = `${removed.list}/`;
  if (!listPointer.startsWith(prefix)) return listPointer;
  const rest = listPointer.slice(prefix.length);
  const cut = rest.indexOf("/");
  const head = Number(cut === -1 ? rest : rest.slice(0, cut));
  if (head <= removed.index) return listPointer;
  return `${prefix}${head - 1}${cut === -1 ? "" : rest.slice(cut)}`;
}

/** Every step of the tree in order with its pointer. */
export function flatten(
  steps: Step[],
  listPointer: string = rootList,
): { pointer: string; step: Step }[] {
  return steps.flatMap((step, index) => {
    const pointer = `${listPointer}/${index}`;
    return [
      { pointer, step },
      ...childLists(step).flatMap((child) =>
        flatten(child.steps, `${pointer}${child.slot}`),
      ),
    ];
  });
}

export function allKeys(steps: Step[]): string[] {
  return flatten(steps).map((item) => item.step.key);
}

/** The deepest branch nesting of the tree; a flat list is 0. */
export function depth(steps: Step[]): number {
  return Math.max(
    0,
    ...steps.flatMap((step) =>
      childLists(step).map((child) => 1 + depth(child.steps)),
    ),
  );
}

export function uniqueKey(type: StepType, keys: readonly string[]): string {
  let index = 1;
  while (keys.includes(`${type}_${index}`)) index += 1;
  return `${type}_${index}`;
}

// X-10
/** A new step of a palette type with a key unique over the tree and the fields its schema requires. */
export function newStep(type: StepType, keys: readonly string[]): Step {
  const key = uniqueKey(type, keys);
  switch (type) {
    case "channel":
      return { type, key, channel: "email", template: "" };
    case "delay":
      return { type, key, duration: "PT1H" };
    case "digest":
      return { type, key, digest_key: "", mode: "fixed", max_wait: "PT1H" };
    case "throttle":
      return { type, key, throttle_key: "", limit: 1, window: "PT1H" };
    case "condition":
      return {
        type,
        key,
        branches: [{ when: { exists: { var: "" } }, steps: [] }],
        else: [],
      };
    case "wait_for_event":
      return {
        type,
        key,
        event_type: "",
        correlation_key: "",
        timeout: "P1D",
        on_timeout: [],
      };
    case "time_window":
      return {
        type,
        key,
        windows: [
          {
            days: ["mon", "tue", "wed", "thu", "fri"],
            start: "09:00",
            end: "18:00",
          },
        ],
      };
    case "webhook":
      return { type, key, endpoint: "", event_type: "" };
  }
}

export const patterns = {
  stepKey: /^[a-z][a-z0-9_]{0,63}$/,
  slug: /^[a-z0-9]+(-[a-z0-9]+)*$/,
  templateKey: /^[a-z0-9]+(-[a-z0-9]+)*$/,
  routeKey: /^[a-z][a-z0-9_]{0,63}$/,
  endpointKey: /^[a-z0-9]+(-[a-z0-9]+)*$/,
  eventType: /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/,
  localTime: /^([01][0-9]|2[0-3]):[0-5][0-9]$/,
  dataPointer: /^(\/[A-Za-z0-9_-]+)+$/,
};

export interface Issue {
  field: string;
  code: "required" | "invalid_format";
}

function need(value: string | undefined, field: string): Issue[] {
  return value === undefined || value.trim() === ""
    ? [{ field, code: "required" }]
    : [];
}

function shape(
  value: string | undefined,
  field: string,
  test: (value: string) => boolean,
): Issue[] {
  return value === undefined || value === "" || test(value)
    ? []
    : [{ field, code: "invalid_format" }];
}

// X-10
/** Field problems the editor marks before the publication gate runs; the gate stays the authority. */
export function stepIssues(step: Step): Issue[] {
  const own = shape(step.key, "key", (value) => patterns.stepKey.test(value));
  switch (step.type) {
    case "channel":
      return [
        ...own,
        ...need(step.template, "template"),
        ...shape(step.template, "template", (v) =>
          patterns.templateKey.test(v),
        ),
        ...(step.channel === undefined && step.route === undefined
          ? [{ field: "channel", code: "required" as const }]
          : []),
        ...(step.timing === "next_break"
          ? need(step.max_defer, "max_defer")
          : []),
        ...shape(step.max_defer, "max_defer", isDuration),
      ];
    case "delay":
      return [
        ...own,
        ...(step.duration === undefined && step.until === undefined
          ? [{ field: "duration", code: "required" as const }]
          : []),
        ...shape(step.duration, "duration", isDuration),
        ...shape(step.until, "until", (v) => patterns.dataPointer.test(v)),
      ];
    case "digest":
      return [
        ...own,
        ...need(step.digest_key, "digest_key"),
        ...shape(step.max_wait, "max_wait", isDuration),
        ...shape(step.debounce, "debounce", isDuration),
        ...(step.mode === "scheduled" ? need(step.schedule, "schedule") : []),
      ];
    case "throttle":
      return [
        ...own,
        ...need(step.throttle_key, "throttle_key"),
        ...shape(step.window, "window", isDuration),
      ];
    case "condition":
      return own;
    case "wait_for_event":
      return [
        ...own,
        ...need(step.event_type, "event_type"),
        ...shape(step.event_type, "event_type", (v) =>
          patterns.eventType.test(v),
        ),
        ...need(step.correlation_key, "correlation_key"),
        ...need(step.timeout, "timeout"),
        ...shape(step.timeout, "timeout", isDuration),
      ];
    case "time_window":
      return [
        ...own,
        ...step.windows.flatMap((window, index) => [
          ...shape(window.start, `windows/${index}/start`, (v) =>
            patterns.localTime.test(v),
          ),
          ...shape(window.end, `windows/${index}/end`, (v) =>
            patterns.localTime.test(v),
          ),
          ...(window.days.length === 0
            ? [{ field: `windows/${index}/days`, code: "required" as const }]
            : []),
        ]),
      ];
    case "webhook":
      return [
        ...own,
        ...need(step.endpoint, "endpoint"),
        ...shape(step.endpoint, "endpoint", (v) =>
          patterns.endpointKey.test(v),
        ),
        ...need(step.event_type, "event_type"),
        ...shape(step.event_type, "event_type", (v) =>
          patterns.eventType.test(v),
        ),
      ];
  }
}

// X-9
/** Whether the panel may edit a field: every field of a panel-managed workflow, only the marked control fields of a code-managed one. */
export function editable(
  managedBy: "panel" | "code",
  controls: readonly string[],
  pointer: string,
): boolean {
  return managedBy === "panel" || controls.includes(pointer);
}

/** The steps that run before a step on its own path: the earlier steps of each list from the root down to it. */
export function earlierSteps(steps: Step[], stepPointer: string): Step[] {
  const rest = split(parent(stepPointer).list);
  if (rest === null) return [];
  const found: Step[] = [];
  let list: Step[] = steps;
  let remaining = [...rest, String(parent(stepPointer).index)];
  while (remaining.length > 0) {
    const index = Number(remaining[0]);
    found.push(...list.slice(0, index));
    const step = list[index];
    if (step === undefined || remaining.length === 1) break;
    const slotLength = remaining[1] === "branches" ? 3 : 1;
    const own = childList(step, remaining.slice(1, 1 + slotLength));
    if (own === null) break;
    list = own;
    remaining = remaining.slice(1 + slotLength);
  }
  return found;
}

/** A copy of an object without one of its fields. */
export function omit<T extends object, K extends keyof T>(
  value: T,
  key: K,
): Omit<T, K> {
  return Object.fromEntries(
    Object.entries(value).filter(([name]) => name !== key),
  ) as Omit<T, K>;
}
