import { useId, useState, type DragEvent } from "react";
import { useI18n } from "../../i18n/i18n";
import {
  childLists,
  stepIssues,
  stepTypes,
  type Step,
  type StepType,
} from "./model";

const mime = "application/x-relay-step";

type Payload = { kind: "new"; type: StepType } | { kind: "move"; pointer: string };

function readPayload(event: DragEvent): Payload | null {
  const raw = event.dataTransfer.getData(mime);
  if (raw === "") return null;
  try {
    const value = JSON.parse(raw) as Payload;
    return value.kind === "new" || value.kind === "move" ? value : null;
  } catch {
    return null;
  }
}

export interface CanvasActions {
  add: (list: string, index: number, type: StepType) => void;
  move: (from: string, list: string, index: number) => void;
  remove: (pointer: string) => void;
  select: (pointer: string) => void;
  addBranch: (pointer: string) => void;
  removeBranch: (pointer: string, branch: number) => void;
}

function stepSummary(step: Step): string {
  switch (step.type) {
    case "channel":
      return [
        step.channel ?? (typeof step.route === "string" ? `route:${step.route}` : "route"),
        step.template,
      ]
        .filter((part) => part !== "")
        .join(" · ");
    case "delay":
      return step.duration ?? step.until ?? "";
    case "digest":
      return `${step.mode} ${step.max_wait ?? step.schedule ?? ""}`.trim();
    case "throttle":
      return `${step.limit} / ${step.window ?? step.calendar ?? step.until ?? ""}`;
    case "condition":
      return "";
    case "wait_for_event":
      return `${step.event_type} ≤ ${step.timeout}`;
    case "time_window":
      return step.windows
        .map((window) => `${window.days.join(",")} ${window.start}–${window.end}`)
        .join("; ");
    case "webhook":
      return `${step.endpoint} · ${step.event_type}`;
  }
}

// X-10
/** The eight step types; each can be dragged onto the canvas. */
export function Palette({ disabled }: { disabled: boolean }) {
  const { t } = useI18n();
  return (
    <section className="palette panel stack" aria-labelledby="palette-title">
      <h2 id="palette-title" className="small-heading">
        {t("wf.palette")}
      </h2>
      <p className="small muted">
        {disabled ? t("wf.paletteLocked") : t("wf.paletteHint")}
      </p>
      <ul className="plain stack tight">
        {stepTypes.map((type) => (
          <li
            key={type}
            className={`palette-item step-${type}`}
            draggable={!disabled}
            data-palette={type}
            onDragStart={(event) => {
              event.dataTransfer.setData(
                mime,
                JSON.stringify({ kind: "new", type } satisfies Payload),
              );
              event.dataTransfer.effectAllowed = "copy";
            }}
          >
            {t(`step.${type}`)}
          </li>
        ))}
      </ul>
    </section>
  );
}

function DropZone({
  list,
  index,
  locked,
  actions,
}: {
  list: string;
  index: number;
  locked: boolean;
  actions: CanvasActions;
}) {
  const { t } = useI18n();
  const id = useId();
  const [over, setOver] = useState(false);
  const [open, setOpen] = useState(false);
  if (locked) return <div className="drop-zone locked" aria-hidden="true" />;
  return (
    <div
      className={`drop-zone${over ? " over" : ""}`}
      data-drop={`${list}/${index}`}
      onDragOver={(event) => {
        event.preventDefault();
        setOver(true);
      }}
      onDragLeave={() => {
        setOver(false);
      }}
      onDrop={(event) => {
        event.preventDefault();
        setOver(false);
        const payload = readPayload(event);
        if (payload?.kind === "new") actions.add(list, index, payload.type);
        else if (payload?.kind === "move") actions.move(payload.pointer, list, index);
      }}
    >
      {open ? (
        <span className="row">
          <label className="visually-hidden" htmlFor={id}>
            {t("wf.chooseStep")}
          </label>
          <select
            id={id}
            defaultValue=""
            onChange={(event) => {
              const type = event.target.value as StepType | "";
              setOpen(false);
              if (type !== "") actions.add(list, index, type);
            }}
          >
            <option value="">{t("wf.chooseStep")}</option>
            {stepTypes.map((type) => (
              <option key={type} value={type}>
                {t(`step.${type}`)}
              </option>
            ))}
          </select>
          <button
            type="button"
            onClick={() => {
              setOpen(false);
            }}
          >
            {t("common.close")}
          </button>
        </span>
      ) : (
        <button
          type="button"
          className="add-step"
          aria-label={t("wf.addHere")}
          onClick={() => {
            setOpen(true);
          }}
        >
          +
        </button>
      )}
    </div>
  );
}

function StepList({
  steps,
  list,
  locked,
  selected,
  actions,
}: {
  steps: Step[];
  list: string;
  locked: boolean;
  selected: string | null;
  actions: CanvasActions;
}) {
  return (
    <ol className="flow plain" data-list={list}>
      <li className="flow-gap">
        <DropZone list={list} index={0} locked={locked} actions={actions} />
      </li>
      {steps.map((step, index) => (
        <StepCard
          key={`${step.key}-${index}`}
          step={step}
          pointer={`${list}/${index}`}
          index={index}
          last={index === steps.length - 1}
          locked={locked}
          selected={selected}
          actions={actions}
          list={list}
        />
      ))}
    </ol>
  );
}

function StepCard({
  step,
  pointer,
  index,
  last,
  list,
  locked,
  selected,
  actions,
}: {
  step: Step;
  pointer: string;
  index: number;
  last: boolean;
  list: string;
  locked: boolean;
  selected: string | null;
  actions: CanvasActions;
}) {
  const { t } = useI18n();
  const issues = stepIssues(step);
  const isSelected = selected === pointer;
  return (
    <>
      <li
        className={`step-card step-${step.type}${isSelected ? " selected" : ""}`}
        data-step={step.key}
        draggable={!locked}
        onDragStart={(event) => {
          event.stopPropagation();
          event.dataTransfer.setData(
            mime,
            JSON.stringify({ kind: "move", pointer } satisfies Payload),
          );
          event.dataTransfer.effectAllowed = "move";
        }}
      >
        <div className="row step-head">
          <button
            type="button"
            className="step-select"
            aria-pressed={isSelected}
            onClick={() => {
              actions.select(pointer);
            }}
          >
            <span className="step-type">{t(`step.${step.type}`)}</span>
            <code className="mono">{step.key}</code>
            <span className="small muted">{stepSummary(step)}</span>
          </button>
          {issues.length > 0 && (
            <span className="badge tone-warn" data-step-issues={issues.length}>
              <span className="badge-label">
                {t("wf.issues", { count: issues.length })}
              </span>
            </span>
          )}
          {!locked && (
            <span className="row step-tools">
              <button
                type="button"
                disabled={index === 0}
                aria-label={t("wf.moveUp", { key: step.key })}
                onClick={() => {
                  actions.move(pointer, list, index - 1);
                }}
              >
                ↑
              </button>
              <button
                type="button"
                disabled={last}
                aria-label={t("wf.moveDown", { key: step.key })}
                onClick={() => {
                  actions.move(pointer, list, index + 2);
                }}
              >
                ↓
              </button>
              <button
                type="button"
                aria-label={t("wf.remove", { key: step.key })}
                onClick={() => {
                  actions.remove(pointer);
                }}
              >
                ✕
              </button>
            </span>
          )}
        </div>
        {childLists(step).length > 0 && (
          <div className="branches">
            {childLists(step).map((child) => {
              const branch = /^\/branches\/(\d+)\/steps$/.exec(child.slot);
              const number = branch ? Number(branch[1]) : null;
              return (
                <div key={child.slot} className="branch" data-branch={child.slot}>
                  <div className="row branch-head">
                    <span className="small">
                      {number !== null
                        ? t("wf.branch", { n: number + 1 })
                        : child.slot === "/else"
                          ? t("wf.else")
                          : t("wf.onTimeout")}
                    </span>
                    {number !== null &&
                      !locked &&
                      step.type === "condition" &&
                      step.branches.length > 1 && (
                        <button
                          type="button"
                          className="link-button small"
                          onClick={() => {
                            actions.removeBranch(pointer, number);
                          }}
                        >
                          {t("wf.removeBranch", { n: number + 1 })}
                        </button>
                      )}
                  </div>
                  <StepList
                    steps={child.steps}
                    list={`${pointer}${child.slot}`}
                    locked={locked}
                    selected={selected}
                    actions={actions}
                  />
                </div>
              );
            })}
            {step.type === "condition" && !locked && step.branches.length < 10 && (
              <span>
                <button
                  type="button"
                  className="small"
                  onClick={() => {
                    actions.addBranch(pointer);
                  }}
                >
                  {t("wf.addBranch")}
                </button>
              </span>
            )}
          </div>
        )}
      </li>
      <li className="flow-gap">
        <DropZone list={list} index={index + 1} locked={locked} actions={actions} />
      </li>
    </>
  );
}

// X-10
/** The step tree as a vertical flow: drag a palette entry or a step onto a gap, or use the gap's add button and the move buttons from the keyboard. A locked tree shows the structure without any of these. */
export function Canvas({
  steps,
  locked,
  selected,
  actions,
}: {
  steps: Step[];
  locked: boolean;
  selected: string | null;
  actions: CanvasActions;
}) {
  const { t } = useI18n();
  return (
    <section className="canvas panel" aria-labelledby="canvas-title">
      <h2 id="canvas-title" className="small-heading">
        {t("wf.canvas")}
      </h2>
      <div className="flow-start small muted">{t("wf.trigger")}</div>
      <StepList
        steps={steps}
        list="/steps"
        locked={locked}
        selected={selected}
        actions={actions}
      />
      {steps.length === 0 && (
        <p className="muted small">{locked ? t("common.empty") : t("wf.emptyCanvas")}</p>
      )}
    </section>
  );
}
