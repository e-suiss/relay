import { useId, type ReactNode } from "react";
import type { Channel } from "../../api/types";
import { useI18n } from "../../i18n/i18n";
import { durationSeconds, humanDuration, isDuration } from "../../lib/duration";
import { ConditionBuilder } from "./ConditionBuilder";
import { pathOptions } from "./condition";
import {
  channels,
  omit,
  patterns,
  stepIssues,
  weekdays,
  type ChannelStep,
  type Definition,
  type Step,
  type TimeWindow,
  type Variant,
} from "./model";
import { RouteTree } from "./RouteTree";

export interface InspectorContext {
  canEdit: (pointer: string) => boolean;
  structureLocked: boolean;
  definition: Definition;
  earlier: readonly Step[];
  routes: readonly string[];
  templates: readonly string[];
}

function Field({
  label,
  hint,
  invalid,
  children,
  id,
}: {
  label: string;
  hint?: string;
  invalid?: boolean;
  id: string;
  children: ReactNode;
}) {
  return (
    <div className={`field${invalid === true ? " invalid" : ""}`}>
      <label htmlFor={id}>{label}</label>
      {children}
      {hint !== undefined && <span className="small muted">{hint}</span>}
    </div>
  );
}

function TextInput({
  label,
  value,
  pointer,
  ctx,
  onChange,
  pattern,
  placeholder,
  list,
  optional = false,
}: {
  label: string;
  value: string | undefined;
  pointer: string;
  ctx: InspectorContext;
  onChange: (value: string | undefined) => void;
  pattern?: RegExp;
  placeholder?: string;
  list?: string;
  optional?: boolean;
}) {
  const id = useId();
  const text = value ?? "";
  const invalid = text !== "" && pattern !== undefined && !pattern.test(text);
  return (
    <Field label={label} id={id} invalid={invalid}>
      <input
        id={id}
        value={text}
        disabled={!ctx.canEdit(pointer)}
        aria-invalid={invalid}
        data-pointer={pointer}
        placeholder={placeholder}
        list={list}
        onChange={(event) => {
          const next = event.target.value;
          onChange(optional && next === "" ? undefined : next);
        }}
      />
    </Field>
  );
}

function DurationInput({
  label,
  value,
  pointer,
  ctx,
  onChange,
  optional = false,
}: {
  label: string;
  value: string | undefined;
  pointer: string;
  ctx: InspectorContext;
  onChange: (value: string | undefined) => void;
  optional?: boolean;
}) {
  const { t, locale } = useI18n();
  const id = useId();
  const text = value ?? "";
  const seconds = durationSeconds(text);
  const invalid = text !== "" && !isDuration(text);
  return (
    <Field
      label={label}
      id={id}
      invalid={invalid}
      hint={
        seconds === null ? t("wf.durationHint") : humanDuration(seconds, locale)
      }
    >
      <input
        id={id}
        value={text}
        placeholder="PT1H"
        disabled={!ctx.canEdit(pointer)}
        aria-invalid={invalid}
        data-pointer={pointer}
        onChange={(event) => {
          const next = event.target.value.trim().toUpperCase();
          onChange(optional && next === "" ? undefined : next);
        }}
      />
    </Field>
  );
}

function NumberInput({
  label,
  value,
  pointer,
  ctx,
  onChange,
  min = 0,
}: {
  label: string;
  value: number | undefined;
  pointer: string;
  ctx: InspectorContext;
  onChange: (value: number | undefined) => void;
  min?: number;
}) {
  const id = useId();
  return (
    <Field label={label} id={id}>
      <input
        id={id}
        type="number"
        min={min}
        value={value ?? ""}
        disabled={!ctx.canEdit(pointer)}
        data-pointer={pointer}
        onChange={(event) => {
          const raw = event.target.value;
          onChange(raw === "" ? undefined : Number(raw));
        }}
      />
    </Field>
  );
}

function Choice<T extends string>({
  label,
  value,
  options,
  pointer,
  ctx,
  onChange,
  render,
  empty,
}: {
  label: string;
  value: T | undefined;
  options: readonly T[];
  pointer: string;
  ctx: InspectorContext;
  onChange: (value: T | undefined) => void;
  render: (value: T) => string;
  empty?: string;
}) {
  const id = useId();
  return (
    <Field label={label} id={id}>
      <select
        id={id}
        value={value ?? ""}
        disabled={!ctx.canEdit(pointer)}
        data-pointer={pointer}
        onChange={(event) => {
          const raw = event.target.value;
          onChange(raw === "" ? undefined : (raw as T));
        }}
      >
        {empty !== undefined && <option value="">{empty}</option>}
        {options.map((option) => (
          <option key={option} value={option}>
            {render(option)}
          </option>
        ))}
      </select>
    </Field>
  );
}

function without<T extends object, K extends keyof T>(value: T, key: K): T {
  return omit(value, key) as unknown as T;
}

function set<T extends object, K extends keyof T>(
  value: T,
  key: K,
  next: T[K] | undefined,
): T {
  return next === undefined ? without(value, key) : { ...value, [key]: next };
}

// WF-50
function Variants({
  step,
  pointer,
  ctx,
  onChange,
}: {
  step: ChannelStep;
  pointer: string;
  ctx: InspectorContext;
  onChange: (step: Step) => void;
}) {
  const { t } = useI18n();
  const variants = step.variants ?? [];
  const change = (next: Variant[]) => {
    onChange(set(step, "variants", next.length === 0 ? undefined : next));
  };
  return (
    <fieldset className="stack tight">
      <legend>{t("wf.variants")}</legend>
      <p className="small muted">{t("wf.variantsHint")}</p>
      {variants.map((variant, index) => (
        <div key={index} className="row filters">
          <TextInput
            label={t("wf.variantKey")}
            value={variant.key}
            pointer={`${pointer}/variants/${index}/key`}
            ctx={ctx}
            pattern={patterns.stepKey}
            onChange={(value) => {
              change(
                variants.map((item, at) =>
                  at === index ? { ...item, key: value ?? "" } : item,
                ),
              );
            }}
          />
          <NumberInput
            label={t("wf.weight")}
            value={variant.weight}
            pointer={`${pointer}/variants/${index}/weight`}
            ctx={ctx}
            onChange={(value) => {
              change(
                variants.map((item, at) =>
                  at === index ? { ...item, weight: value ?? 0 } : item,
                ),
              );
            }}
          />
          <TextInput
            label={t("wf.template")}
            value={variant.template}
            pointer={`${pointer}/variants/${index}/template`}
            ctx={ctx}
            pattern={patterns.templateKey}
            list="wf-templates"
            onChange={(value) => {
              change(
                variants.map((item, at) =>
                  at === index ? { ...item, template: value ?? "" } : item,
                ),
              );
            }}
          />
          {!ctx.structureLocked && (
            <button
              type="button"
              onClick={() => {
                change(variants.filter((_item, at) => at !== index));
              }}
            >
              {t("wf.removeVariant")}
            </button>
          )}
        </div>
      ))}
      {!ctx.structureLocked && (
        <span>
          <button
            type="button"
            onClick={() => {
              change([
                ...variants,
                {
                  key: `variant_${variants.length + 1}`,
                  weight: 50,
                  template: step.template,
                },
              ]);
            }}
          >
            {t("wf.addVariant")}
          </button>
        </span>
      )}
    </fieldset>
  );
}

// WF-13
// WF-50
// WF-56
function ChannelForm({
  step,
  pointer,
  ctx,
  onChange,
}: {
  step: ChannelStep;
  pointer: string;
  ctx: InspectorContext;
  onChange: (step: Step) => void;
}) {
  const { t } = useI18n();
  const targetId = useId();
  const usesRoute = step.route !== undefined;
  return (
    <>
      <fieldset className="row" disabled={!ctx.canEdit(`${pointer}/channel`)}>
        <legend id={targetId}>{t("wf.target")}</legend>
        <label className="inline">
          <input
            type="radio"
            name={`${pointer}-target`}
            checked={!usesRoute}
            onChange={() => {
              onChange({
                ...without(step, "route"),
                channel: step.channel ?? "email",
              });
            }}
          />
          {t("wf.targetChannel")}
        </label>
        <label className="inline">
          <input
            type="radio"
            name={`${pointer}-target`}
            checked={usesRoute}
            onChange={() => {
              onChange({
                ...without(step, "channel"),
                route: ctx.routes[0] ?? "",
              });
            }}
          />
          {t("wf.targetRoute")}
        </label>
      </fieldset>
      {usesRoute ? (
        typeof step.route === "string" ? (
          <Choice
            label={t("wf.route")}
            value={step.route === "" ? undefined : step.route}
            options={
              ctx.routes.includes(step.route) || step.route === ""
                ? ctx.routes
                : [step.route, ...ctx.routes]
            }
            pointer={`${pointer}/route`}
            ctx={ctx}
            empty={t("wf.chooseRoute")}
            render={(value) => value}
            onChange={(value) => {
              onChange({ ...step, route: value ?? "" });
            }}
          />
        ) : (
          <div className="stack tight">
            <span className="small muted">{t("wf.inlineRoute")}</span>
            <RouteTree node={step.route} />
          </div>
        )
      ) : (
        <Choice<Channel>
          label={t("why.channel")}
          value={step.channel}
          options={channels}
          pointer={`${pointer}/channel`}
          ctx={ctx}
          render={(value) => t(`channel.${value}`)}
          onChange={(value) => {
            onChange(set(step, "channel", value));
          }}
        />
      )}
      <TextInput
        label={t("wf.template")}
        value={step.template}
        pointer={`${pointer}/template`}
        ctx={ctx}
        pattern={patterns.templateKey}
        list="wf-templates"
        onChange={(value) => {
          onChange({ ...step, template: value ?? "" });
        }}
      />
      <TextInput
        label={t("wf.digestTemplate")}
        value={step.digest_template}
        pointer={`${pointer}/digest_template`}
        ctx={ctx}
        pattern={patterns.templateKey}
        list="wf-templates"
        optional
        onChange={(value) => {
          onChange(set(step, "digest_template", value));
        }}
      />
      <Choice
        label={t("wf.timing")}
        value={step.timing}
        options={["immediate", "next_break"] as const}
        pointer={`${pointer}/timing`}
        ctx={ctx}
        empty={t("wf.timingDefault")}
        render={(value) => t(`wf.timing.${value}`)}
        onChange={(value) => {
          onChange(set(step, "timing", value));
        }}
      />
      {step.timing === "next_break" && (
        <DurationInput
          label={t("wf.maxDefer")}
          value={step.max_defer}
          pointer={`${pointer}/max_defer`}
          ctx={ctx}
          optional
          onChange={(value) => {
            onChange(set(step, "max_defer", value));
          }}
        />
      )}
      <Variants step={step} pointer={pointer} ctx={ctx} onChange={onChange} />
    </>
  );
}

function WindowRow({
  window,
  index,
  pointer,
  ctx,
  onChange,
  onRemove,
}: {
  window: TimeWindow;
  index: number;
  pointer: string;
  ctx: InspectorContext;
  onChange: (window: TimeWindow) => void;
  onRemove: (() => void) | null;
}) {
  const { t } = useI18n();
  const base = `${pointer}/windows/${index}`;
  return (
    <fieldset className="stack tight">
      <legend>{t("wf.windowN", { n: index + 1 })}</legend>
      <div className="row" role="group" aria-label={t("wf.days")}>
        {weekdays.map((day) => (
          <label key={day} className="inline">
            <input
              type="checkbox"
              checked={window.days.includes(day)}
              disabled={!ctx.canEdit(`${base}/days`)}
              onChange={(event) => {
                onChange({
                  ...window,
                  days: event.target.checked
                    ? weekdays.filter(
                        (item) => item === day || window.days.includes(item),
                      )
                    : window.days.filter((item) => item !== day),
                });
              }}
            />
            {t(`wf.day.${day}`)}
          </label>
        ))}
      </div>
      <div className="row filters">
        <TextInput
          label={t("wf.start")}
          value={window.start}
          pointer={`${base}/start`}
          ctx={ctx}
          pattern={patterns.localTime}
          placeholder="09:00"
          onChange={(value) => {
            onChange({ ...window, start: value ?? "" });
          }}
        />
        <TextInput
          label={t("wf.end")}
          value={window.end}
          pointer={`${base}/end`}
          ctx={ctx}
          pattern={patterns.localTime}
          placeholder="18:00"
          onChange={(value) => {
            onChange({ ...window, end: value ?? "" });
          }}
        />
        {onRemove && (
          <button type="button" onClick={onRemove}>
            {t("wf.removeWindow")}
          </button>
        )}
      </div>
    </fieldset>
  );
}

function StepForm({
  step,
  pointer,
  ctx,
  onChange,
}: {
  step: Step;
  pointer: string;
  ctx: InspectorContext;
  onChange: (step: Step) => void;
}) {
  const { t } = useI18n();
  const options = pathOptions(ctx.definition, ctx.earlier);
  switch (step.type) {
    case "channel":
      return (
        <ChannelForm
          step={step}
          pointer={pointer}
          ctx={ctx}
          onChange={onChange}
        />
      );
    case "delay":
      return (
        <>
          <DurationInput
            label={t("wf.duration")}
            value={step.duration}
            pointer={`${pointer}/duration`}
            ctx={ctx}
            optional
            onChange={(value) => {
              onChange(set(step, "duration", value));
            }}
          />
          <TextInput
            label={t("wf.until")}
            value={step.until}
            pointer={`${pointer}/until`}
            ctx={ctx}
            pattern={patterns.dataPointer}
            placeholder="/appointment/starts_at"
            optional
            onChange={(value) => {
              onChange(set(step, "until", value));
            }}
          />
        </>
      );
    case "digest":
      return (
        <>
          <TextInput
            label={t("wf.digestKey")}
            value={step.digest_key}
            pointer={`${pointer}/digest_key`}
            ctx={ctx}
            placeholder="{{data.thread_id}}"
            onChange={(value) => {
              onChange({ ...step, digest_key: value ?? "" });
            }}
          />
          <Choice
            label={t("wf.mode")}
            value={step.mode}
            options={["fixed", "sliding", "scheduled"] as const}
            pointer={`${pointer}/mode`}
            ctx={ctx}
            render={(value) => t(`wf.mode.${value}`)}
            onChange={(value) => {
              onChange({ ...step, mode: value ?? "fixed" });
            }}
          />
          <DurationInput
            label={t("wf.maxWait")}
            value={step.max_wait}
            pointer={`${pointer}/max_wait`}
            ctx={ctx}
            optional
            onChange={(value) => {
              onChange(set(step, "max_wait", value));
            }}
          />
          <DurationInput
            label={t("wf.debounce")}
            value={step.debounce}
            pointer={`${pointer}/debounce`}
            ctx={ctx}
            optional
            onChange={(value) => {
              onChange(set(step, "debounce", value));
            }}
          />
          {step.mode === "scheduled" && (
            <TextInput
              label={t("wf.schedule")}
              value={step.schedule}
              pointer={`${pointer}/schedule`}
              ctx={ctx}
              placeholder="FREQ=DAILY;BYHOUR=9"
              optional
              onChange={(value) => {
                onChange(set(step, "schedule", value));
              }}
            />
          )}
          <NumberInput
            label={t("wf.maxItems")}
            value={step.max_items}
            pointer={`${pointer}/max_items`}
            ctx={ctx}
            min={1}
            onChange={(value) => {
              onChange(set(step, "max_items", value));
            }}
          />
        </>
      );
    case "throttle":
      return (
        <>
          <TextInput
            label={t("wf.throttleKey")}
            value={step.throttle_key}
            pointer={`${pointer}/throttle_key`}
            ctx={ctx}
            placeholder="{{data.account_id}}"
            onChange={(value) => {
              onChange({ ...step, throttle_key: value ?? "" });
            }}
          />
          <NumberInput
            label={t("wf.limit")}
            value={step.limit}
            pointer={`${pointer}/limit`}
            ctx={ctx}
            min={1}
            onChange={(value) => {
              onChange({ ...step, limit: value ?? 1 });
            }}
          />
          <DurationInput
            label={t("wf.window")}
            value={step.window}
            pointer={`${pointer}/window`}
            ctx={ctx}
            optional
            onChange={(value) => {
              onChange(set(step, "window", value));
            }}
          />
          <Choice
            label={t("wf.calendar")}
            value={step.calendar}
            options={["day", "week"] as const}
            pointer={`${pointer}/calendar`}
            ctx={ctx}
            empty={t("wf.none")}
            render={(value) => t(`wf.calendar.${value}`)}
            onChange={(value) => {
              onChange(set(step, "calendar", value));
            }}
          />
        </>
      );
    case "condition":
      return (
        <>
          {step.branches.map((branch, index) => (
            <fieldset key={index} className="stack tight">
              <legend>{t("wf.branchWhen", { n: index + 1 })}</legend>
              <ConditionBuilder
                condition={branch.when}
                options={options}
                disabled={!ctx.canEdit(`${pointer}/branches/${index}/when`)}
                onChange={(when) => {
                  onChange({
                    ...step,
                    branches: step.branches.map((item, at) =>
                      at === index
                        ? { ...item, when: when ?? { exists: { var: "" } } }
                        : item,
                    ),
                  });
                }}
              />
            </fieldset>
          ))}
          {!ctx.structureLocked && (
            <label className="inline">
              <input
                type="checkbox"
                checked={step.else !== undefined}
                onChange={(event) => {
                  onChange(
                    event.target.checked
                      ? { ...step, else: [] }
                      : without(step, "else"),
                  );
                }}
              />
              {t("wf.hasElse")}
            </label>
          )}
        </>
      );
    case "wait_for_event":
      return (
        <>
          <TextInput
            label={t("wf.eventType")}
            value={step.event_type}
            pointer={`${pointer}/event_type`}
            ctx={ctx}
            pattern={patterns.eventType}
            placeholder="order.paid"
            onChange={(value) => {
              onChange({ ...step, event_type: value ?? "" });
            }}
          />
          <TextInput
            label={t("wf.correlationKey")}
            value={step.correlation_key}
            pointer={`${pointer}/correlation_key`}
            ctx={ctx}
            placeholder="{{data.order_id}}"
            onChange={(value) => {
              onChange({ ...step, correlation_key: value ?? "" });
            }}
          />
          <DurationInput
            label={t("wf.timeout")}
            value={step.timeout}
            pointer={`${pointer}/timeout`}
            ctx={ctx}
            onChange={(value) => {
              onChange({ ...step, timeout: value ?? "" });
            }}
          />
          <fieldset className="stack tight">
            <legend>{t("wf.match")}</legend>
            <ConditionBuilder
              condition={step.match}
              options={options}
              incoming
              disabled={!ctx.canEdit(`${pointer}/match`)}
              onChange={(match) => {
                onChange(set(step, "match", match));
              }}
            />
          </fieldset>
          {!ctx.structureLocked && (
            <label className="inline">
              <input
                type="checkbox"
                checked={step.on_timeout !== undefined}
                onChange={(event) => {
                  onChange(
                    event.target.checked
                      ? { ...step, on_timeout: [] }
                      : without(step, "on_timeout"),
                  );
                }}
              />
              {t("wf.hasOnTimeout")}
            </label>
          )}
        </>
      );
    case "time_window":
      return (
        <>
          {step.windows.map((window, index) => (
            <WindowRow
              key={index}
              window={window}
              index={index}
              pointer={pointer}
              ctx={ctx}
              onChange={(next) => {
                onChange({
                  ...step,
                  windows: step.windows.map((item, at) =>
                    at === index ? next : item,
                  ),
                });
              }}
              onRemove={
                ctx.structureLocked || step.windows.length === 1
                  ? null
                  : () => {
                      onChange({
                        ...step,
                        windows: step.windows.filter(
                          (_item, at) => at !== index,
                        ),
                      });
                    }
              }
            />
          ))}
          {!ctx.structureLocked && (
            <span>
              <button
                type="button"
                onClick={() => {
                  onChange({
                    ...step,
                    windows: [
                      ...step.windows,
                      { days: ["sat", "sun"], start: "10:00", end: "16:00" },
                    ],
                  });
                }}
              >
                {t("wf.addWindow")}
              </button>
            </span>
          )}
        </>
      );
    case "webhook":
      return (
        <>
          <TextInput
            label={t("wf.endpoint")}
            value={step.endpoint}
            pointer={`${pointer}/endpoint`}
            ctx={ctx}
            pattern={patterns.endpointKey}
            onChange={(value) => {
              onChange({ ...step, endpoint: value ?? "" });
            }}
          />
          <TextInput
            label={t("wf.eventType")}
            value={step.event_type}
            pointer={`${pointer}/event_type`}
            ctx={ctx}
            pattern={patterns.eventType}
            onChange={(value) => {
              onChange({ ...step, event_type: value ?? "" });
            }}
          />
        </>
      );
  }
}

// X-9
// X-10
/** The fields of the selected step; on a code-managed workflow only the marked control fields can be changed. */
export function Inspector({
  step,
  pointer,
  ctx,
  onChange,
}: {
  step: Step | null;
  pointer: string | null;
  ctx: InspectorContext;
  onChange: (step: Step) => void;
}) {
  const { t } = useI18n();
  if (step === null || pointer === null)
    return (
      <section className="inspector panel" aria-labelledby="inspector-title">
        <h2 id="inspector-title" className="small-heading">
          {t("wf.inspector")}
        </h2>
        <p className="muted small">{t("wf.selectStep")}</p>
      </section>
    );
  const issues = stepIssues(step);
  return (
    <section
      className="inspector panel stack"
      aria-labelledby="inspector-title"
      data-inspector={step.key}
    >
      <h2 id="inspector-title" className="small-heading">
        {t(`step.${step.type}`)} · <code className="mono">{step.key}</code>
      </h2>
      <TextInput
        label={t("wf.stepKey")}
        value={step.key}
        pointer={`${pointer}/key`}
        ctx={ctx}
        pattern={patterns.stepKey}
        onChange={(value) => {
          onChange({ ...step, key: value ?? "" });
        }}
      />
      <StepForm step={step} pointer={pointer} ctx={ctx} onChange={onChange} />
      {issues.length > 0 && (
        <ul className="plain small" aria-label={t("wf.issuesTitle")}>
          {issues.map((issue) => (
            <li key={`${issue.field}-${issue.code}`}>
              <code className="mono">{issue.field}</code>{" "}
              {t(`gate.code.${issue.code}`)}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
