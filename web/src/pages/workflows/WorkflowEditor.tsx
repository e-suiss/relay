import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { ApiError, etag, idempotencyKey } from "../../api/client";
import { useFetch, useGet, useMutation } from "../../api/hooks";
import type { FieldError, WorkflowPublicationCheck } from "../../api/pending";
import type { Channel, Page, ServerSchemas } from "../../api/types";
import { Link } from "../../app/router";
import { Loadable, Mono, Section } from "../../components/data";
import { useI18n } from "../../i18n/i18n";
import { problemText, useStepUp } from "../../session/stepUp";
import { Canvas, Palette, type CanvasActions } from "./Canvas";
import { Inspector, type InspectorContext } from "./Inspector";
import {
  allKeys,
  depth,
  earlierSteps,
  editable,
  flatten,
  getStep,
  insertStep,
  moveStep,
  newStep,
  removeStep,
  omit,
  replaceStep,
  type ConditionStep,
  type Definition,
  type Step,
} from "./model";
import { PublicationBadge } from "./Workflows";
import {
  AudiencePanel,
  NotificationsPanel,
  PreviewPanel,
  SendModePanel,
  TestSendPanel,
  VersionsPanel,
} from "./WorkflowPanels";

type Workflow = ServerSchemas["Workflow"];
type WorkflowVersion = ServerSchemas["WorkflowVersion"];
type PublicationAccepted = ServerSchemas["PublicationAccepted"];
type Route = ServerSchemas["Route"];
type Template = ServerSchemas["Template"];
type Category = ServerSchemas["Category"];

const enc = encodeURIComponent;

type Gate =
  | { kind: "loading" }
  | { kind: "check"; result: WorkflowPublicationCheck }
  | { kind: "fallback"; errors: FieldError[]; publishable: boolean }
  | { kind: "error"; message: string };

// X-10
/** The publication gate result before publishing: the dry-run endpoint when the server has it, otherwise the result of the last publication of this draft. */
function useGate(workflow: Workflow, nonce: number): Gate {
  const check = useGet<WorkflowPublicationCheck>(
    `/v1/workflows/${enc(workflow.key)}/publication_check`,
  );
  const { reload } = check;
  useEffect(() => {
    if (nonce > 0) reload();
  }, [nonce, reload]);
  if (check.state.kind === "loading") return { kind: "loading" };
  if (check.state.kind === "ready")
    return { kind: "check", result: check.state.data };
  const error = check.state.error;
  if (error instanceof ApiError && error.status === 404) {
    const last = workflow.last_publication ?? null;
    const errors =
      last !== null &&
      last.status === "rejected" &&
      Date.parse(last.requested_at) >= Date.parse(workflow.updated_at)
        ? (last.errors ?? [{ pointer: "", code: "not_allowed" as const }])
        : null;
    return {
      kind: "fallback",
      errors: errors ?? [],
      publishable: errors === null && workflow.draft !== null,
    };
  }
  if (error instanceof ApiError && error.status === 409)
    return { kind: "fallback", errors: [], publishable: false };
  return { kind: "error", message: problemText(error) };
}

function GatePanel({ gate, dirty }: { gate: Gate; dirty: boolean }) {
  const { t } = useI18n();
  let body: ReactNode;
  if (gate.kind === "loading")
    body = (
      <p role="status" className="muted">
        {t("gate.checking")}
      </p>
    );
  else if (gate.kind === "error")
    body = <p role="alert">{gate.message}</p>;
  else {
    const errors = gate.kind === "check" ? gate.result.errors : gate.errors;
    const passes = gate.kind === "check" ? gate.result.publishable : gate.publishable;
    body = (
      <>
        {gate.kind === "fallback" && (
          <p className="small muted" data-gate-mode="fallback">
            {t("gate.fallback")}
          </p>
        )}
        <p data-gate={passes ? "pass" : "fail"}>
          <span className={`badge tone-${passes ? "ok" : "bad"}`}>
            <span className="badge-label">
              {passes ? t("gate.passes") : t("gate.blocked")}
            </span>
          </span>
        </p>
        {errors.length > 0 && (
          <ul className="plain stack tight">
            {errors.map((error, index) => (
              <li key={`${error.pointer}-${index}`} data-gate-error={error.pointer}>
                <code className="mono">{error.pointer}</code>{" "}
                <strong>{t(`gate.code.${error.code}`)}</strong>
                {error.detail !== undefined && ` — ${error.detail}`}
              </li>
            ))}
          </ul>
        )}
      </>
    );
  }
  return (
    <Section title={t("gate.title")}>
      {dirty && <p className="notice small">{t("gate.unsaved")}</p>}
      {body}
    </Section>
  );
}

function DefinitionSettings({
  definition,
  canEdit,
  locked,
  categories,
  onChange,
}: {
  definition: Definition;
  canEdit: (pointer: string) => boolean;
  locked: boolean;
  categories: readonly Category[];
  onChange: (definition: Definition) => void;
}) {
  const { t } = useI18n();
  const ids = {
    name: useId(),
    description: useId(),
    category: useId(),
    schema: useId(),
    dedup: useId(),
  };
  const [schemaText, setSchemaText] = useState(() =>
    JSON.stringify(definition.event_schema, null, 2),
  );
  const [schemaError, setSchemaError] = useState(false);
  const attributes = Object.entries(definition.recipient_attributes ?? {});
  const setAttributes = (entries: [string, string][]) => {
    onChange({ ...definition, recipient_attributes: Object.fromEntries(entries) });
  };
  return (
    <Section title={t("wf.settings")}>
      <div className="row filters">
        <div className="field grow">
          <label htmlFor={ids.name}>{t("wf.name")}</label>
          <input
            id={ids.name}
            value={definition.name}
            disabled={!canEdit("/name")}
            onChange={(event) => {
              onChange({ ...definition, name: event.target.value });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.category}>{t("why.category")}</label>
          <select
            id={ids.category}
            value={definition.category}
            disabled={!canEdit("/category")}
            onChange={(event) => {
              onChange({ ...definition, category: event.target.value });
            }}
          >
            {!categories.some((item) => item.key === definition.category) && (
              <option value={definition.category}>{definition.category}</option>
            )}
            {categories.map((item) => (
              <option key={item.key} value={item.key}>
                {item.name} ({item.key})
              </option>
            ))}
          </select>
        </div>
      </div>
      <div className="field">
        <label htmlFor={ids.description}>{t("wf.description")}</label>
        <input
          id={ids.description}
          value={definition.description ?? ""}
          disabled={!canEdit("/description")}
          onChange={(event) => {
            const value = event.target.value;
            onChange(
              value === ""
                ? omit(definition, "description")
                : { ...definition, description: value },
            );
          }}
        />
      </div>
      <div className="field">
        <label htmlFor={ids.schema}>{t("wf.eventSchema")}</label>
        <textarea
          id={ids.schema}
          className="mono"
          rows={8}
          value={schemaText}
          aria-invalid={schemaError}
          disabled={!canEdit("/event_schema")}
          onChange={(event) => {
            setSchemaText(event.target.value);
            try {
              const parsed = JSON.parse(event.target.value) as unknown;
              if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
                setSchemaError(false);
                onChange({
                  ...definition,
                  event_schema: parsed as Record<string, unknown>,
                });
              } else setSchemaError(true);
            } catch {
              setSchemaError(true);
            }
          }}
        />
        <span className="small muted">{t("wf.eventSchemaHint")}</span>
      </div>
      <fieldset className="stack tight" disabled={locked}>
        <legend>{t("wf.attributes")}</legend>
        {attributes.map(([name, type], index) => (
          <div key={index} className="row filters">
            <label className="inline">
              {t("wf.attributeName")}
              <input
                value={name}
                onChange={(event) => {
                  setAttributes(
                    attributes.map(
                      (item, at): [string, string] =>
                        at === index ? [event.target.value, item[1]] : item,
                    ),
                  );
                }}
              />
            </label>
            <label className="inline">
              {t("wf.attributeType")}
              <select
                value={type}
                onChange={(event) => {
                  setAttributes(
                    attributes.map(
                      (item, at): [string, string] =>
                        at === index ? [item[0], event.target.value] : item,
                    ),
                  );
                }}
              >
                {["string", "number", "boolean", "timestamp"].map((kind) => (
                  <option key={kind} value={kind}>
                    {kind}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              onClick={() => {
                setAttributes(attributes.filter((_item, at) => at !== index));
              }}
            >
              {t("wf.removeAttribute")}
            </button>
          </div>
        ))}
        <span>
          <button
            type="button"
            onClick={() => {
              setAttributes([...attributes, [`attribute_${attributes.length + 1}`, "string"]]);
            }}
          >
            {t("wf.addAttribute")}
          </button>
        </span>
      </fieldset>
      <div className="field">
        <label htmlFor={ids.dedup}>{t("wf.contentDedup")}</label>
        <input
          id={ids.dedup}
          value={definition.content_dedup?.window ?? ""}
          placeholder="PT10M"
          disabled={!canEdit("/content_dedup/window")}
          onChange={(event) => {
            const value = event.target.value.trim().toUpperCase();
            onChange(
              value === ""
                ? omit(definition, "content_dedup")
                : { ...definition, content_dedup: { window: value } },
            );
          }}
        />
      </div>
    </Section>
  );
}

function usedChannels(steps: Step[]): Channel[] {
  const found = new Set<Channel>();
  for (const { step } of flatten(steps))
    if (step.type === "channel" && step.channel !== undefined)
      found.add(step.channel);
  return [...found];
}

function Editor({
  initial,
  base,
}: {
  initial: Workflow;
  base: Definition;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const fetchJson = useFetch();
  const stepUp = useStepUp();
  const [workflow, setWorkflow] = useState(initial);
  const [definition, setDefinition] = useState<Definition>(base);
  const [dirty, setDirty] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [nonce, setNonce] = useState(0);
  const [polling, setPolling] = useState(false);
  const [versionsKey, setVersionsKey] = useState(0);
  const [saveKey, setSaveKey] = useState(idempotencyKey);
  const gate = useGate(workflow, nonce);
  const routes = useGet<Page<Route>>("/v1/routes", { limit: 100 });
  const templates = useGet<Page<Template>>("/v1/templates", { limit: 100 });
  const categories = useGet<Page<Category>>("/v1/categories", { limit: 100 });

  const locked = workflow.managed_by === "code";
  const controls = useMemo(() => definition.controls ?? [], [definition.controls]);
  const canEdit = useCallback(
    (pointer: string) => editable(workflow.managed_by, controls, pointer),
    [workflow.managed_by, controls],
  );

  const change = (next: Definition) => {
    setDefinition(next);
    setDirty(true);
    setMessage(null);
  };
  const changeSteps = (steps: Step[] | null) => {
    if (steps === null) return;
    if (steps.length > 0 && depth(steps) > 4) {
      setError(t("wf.tooDeep"));
      return;
    }
    if (flatten(steps).length > 50) {
      setError(t("wf.tooMany"));
      return;
    }
    setError(null);
    change({ ...definition, steps });
  };

  const actions: CanvasActions = {
    add: (list, index, type) => {
      const step = newStep(type, allKeys(definition.steps));
      changeSteps(insertStep(definition.steps, list, index, step));
      setSelected(`${list}/${index}`);
    },
    move: (from, list, index) => {
      changeSteps(moveStep(definition.steps, from, list, index));
      setSelected(null);
    },
    remove: (pointer) => {
      changeSteps(removeStep(definition.steps, pointer));
      setSelected(null);
    },
    select: setSelected,
    addBranch: (pointer) => {
      const step = getStep(definition.steps, pointer);
      if (step?.type !== "condition") return;
      const next: ConditionStep = {
        ...step,
        branches: [...step.branches, { when: { exists: { var: "" } }, steps: [] }],
      };
      changeSteps(replaceStep(definition.steps, pointer, next));
    },
    removeBranch: (pointer, branch) => {
      const step = getStep(definition.steps, pointer);
      if (step?.type !== "condition") return;
      changeSteps(
        replaceStep(definition.steps, pointer, {
          ...step,
          branches: step.branches.filter((_item, at) => at !== branch),
        }),
      );
      setSelected(null);
    },
  };

  const fail = (failure: unknown) => {
    setBusy(false);
    if (!stepUp(failure)) setError(problemText(failure));
  };

  const save = () => {
    setBusy(true);
    setError(null);
    mutate<Workflow>(
      "PUT",
      `/v1/workflows/${enc(workflow.key)}`,
      { definition },
      saveKey,
      etag(workflow.version),
    ).then((saved) => {
      setBusy(false);
      setSaveKey(idempotencyKey());
      setWorkflow(saved);
      setDirty(false);
      setMessage(t("wf.saved"));
      setNonce((value) => value + 1);
    }, fail);
  };

  const publish = () => {
    setBusy(true);
    setError(null);
    mutate<PublicationAccepted>(
      "POST",
      `/v1/workflows/${enc(workflow.key)}/publish`,
      {},
      idempotencyKey(),
      etag(workflow.version),
    ).then(() => {
      setBusy(false);
      setMessage(t("wf.publishing"));
      setPolling(true);
    }, fail);
  };

  const promote = (version: number) => {
    setBusy(true);
    setError(null);
    mutate<PublicationAccepted>(
      "POST",
      `/v1/workflows/${enc(workflow.key)}/versions/${version}/promote`,
      undefined,
      idempotencyKey(),
    ).then(() => {
      setBusy(false);
      setMessage(t("wf.reverting", { version }));
      setPolling(true);
    }, fail);
  };

  const switchManager = () => {
    setBusy(true);
    setError(null);
    mutate<Workflow>(
      "POST",
      `/v1/workflows/${enc(workflow.key)}/manager`,
      { managed_by: locked ? "panel" : "code" },
      idempotencyKey(),
      etag(workflow.version),
    ).then((next) => {
      setBusy(false);
      setWorkflow(next);
      setMessage(t("wf.managerChanged", { manager: t(`wf.managedBy.${next.managed_by}`) }));
    }, fail);
  };

  useEffect(() => {
    if (!polling) return;
    let tries = 0;
    const timer = window.setInterval(() => {
      tries += 1;
      fetchJson<Workflow>(`/v1/workflows/${enc(workflow.key)}`).then(
        (next) => {
          const status = next.last_publication?.status;
          if (status !== "pending" || tries >= 20) {
            window.clearInterval(timer);
            setPolling(false);
            setWorkflow(next);
            setVersionsKey((value) => value + 1);
            setNonce((value) => value + 1);
            setMessage(
              status === "published"
                ? t("wf.published", { version: next.published_version ?? 0 })
                : status === "rejected"
                  ? t("wf.rejected")
                  : t("wf.stillPending"),
            );
          }
        },
        () => {
          if (tries >= 20) {
            window.clearInterval(timer);
            setPolling(false);
          }
        },
      );
    }, 1500);
    return () => {
      window.clearInterval(timer);
    };
  }, [polling, fetchJson, workflow.key, t]);

  const publishable =
    !dirty &&
    !busy &&
    !polling &&
    ((gate.kind === "check" && gate.result.publishable) ||
      (gate.kind === "fallback" && gate.publishable));

  const step = selected === null ? null : getStep(definition.steps, selected);
  const ctx: InspectorContext = {
    canEdit,
    structureLocked: locked,
    definition,
    earlier: selected === null ? [] : earlierSteps(definition.steps, selected),
    routes:
      routes.state.kind === "ready"
        ? routes.state.data.data
            .filter((route) => route.state === "active")
            .map((route) => route.key)
        : [],
    templates:
      templates.state.kind === "ready"
        ? templates.state.data.data.map((item) => item.key)
        : [],
  };

  return (
    <div className="stack">
      <div className="row">
        <Mono>{workflow.key}</Mono>
        <span className="badge tone-info" data-managed-by={workflow.managed_by}>
          <span className="badge-label">
            {t(`wf.managedBy.${workflow.managed_by}`)}
          </span>
        </span>
        <span className="muted">
          {workflow.published_version === null || workflow.published_version === undefined
            ? t("wf.notPublished")
            : t("wf.liveVersion", { version: workflow.published_version })}
        </span>
        <PublicationBadge publication={workflow.last_publication} />
      </div>
      {locked && (
        <div className="notice stack tight" role="note" data-code-managed>
          <strong>{t("wf.codeManagedTitle")}</strong>
          <span>{t("wf.codeManagedBody", { count: controls.length })}</span>
        </div>
      )}
      <div className="row toolbar">
        <button
          type="button"
          className="primary"
          disabled={!dirty || busy}
          onClick={save}
        >
          {t("wf.saveDraft")}
        </button>
        <button
          type="button"
          disabled={!dirty || busy}
          onClick={() => {
            setDefinition(
              (workflow.draft as unknown as Definition | null | undefined) ??
                base,
            );
            setDirty(false);
          }}
        >
          {t("wf.discard")}
        </button>
        <button
          type="button"
          data-publish
          disabled={!publishable}
          onClick={publish}
        >
          {t("wf.publish")}
        </button>
        <button type="button" disabled={busy} onClick={switchManager}>
          {locked ? t("wf.toPanel") : t("wf.toCode")}
        </button>
        {message !== null && (
          <span role="status" className="muted">
            {message}
          </span>
        )}
      </div>
      {error !== null && <p role="alert">{error}</p>}
      <GatePanel gate={gate} dirty={dirty} />
      <div className="editor-grid">
        <Palette disabled={locked} />
        <Canvas
          steps={definition.steps}
          locked={locked}
          selected={selected}
          actions={actions}
        />
        <Inspector
          step={step}
          pointer={step === null ? null : selected}
          ctx={ctx}
          onChange={(next) => {
            if (selected !== null)
              changeSteps(replaceStep(definition.steps, selected, next));
          }}
        />
      </div>
      <datalist id="wf-templates">
        {ctx.templates.map((key) => (
          <option key={key} value={key} />
        ))}
      </datalist>
      <DefinitionSettings
        definition={definition}
        canEdit={canEdit}
        locked={locked}
        categories={
          categories.state.kind === "ready" ? categories.state.data.data : []
        }
        onChange={change}
      />
      <PreviewPanel workflowKey={workflow.key} />
      <TestSendPanel
        workflowKey={workflow.key}
        published={workflow.published_version ?? null}
      />
      <VersionsPanel
        key={versionsKey}
        workflowKey={workflow.key}
        published={workflow.published_version ?? null}
        onPromote={promote}
      />
      <NotificationsPanel workflowKey={workflow.key} />
      <AudiencePanel workflowKey={workflow.key} />
      <SendModePanel
        category={definition.category}
        channels={usedChannels(definition.steps)}
      />
    </div>
  );
}

function blank(workflow: Workflow): Definition {
  return {
    name: workflow.name,
    category: "",
    event_schema: { type: "object" },
    steps: [],
  };
}

function EditorFromVersion({ workflow }: { workflow: Workflow }) {
  const version = useGet<WorkflowVersion>(
    `/v1/workflows/${enc(workflow.key)}/versions/${workflow.published_version ?? 0}`,
  );
  return (
    <Loadable state={version.state} onRetry={version.reload}>
      {(found) => (
        <Editor
          initial={workflow}
          base={found.definition as unknown as Definition}
        />
      )}
    </Loadable>
  );
}

// X-8
// X-9
// X-10
// WF-3
// WF-4
/** The visual workflow editor: draft, gate, publish, revert and the reads around one workflow. */
export function WorkflowEditor({ workflowKey }: { workflowKey: string }) {
  const { t } = useI18n();
  const loaded = useGet<Workflow>(`/v1/workflows/${enc(workflowKey)}`);
  return (
    <section className="stack">
      <p>
        <Link to="/workflows">{t("wf.back")}</Link>
      </p>
      <h1>
        {loaded.state.kind === "ready" ? loaded.state.data.name : workflowKey}
      </h1>
      <Loadable state={loaded.state} onRetry={loaded.reload}>
        {(workflow) =>
          workflow.draft === null || workflow.draft === undefined ? (
            workflow.published_version === null ||
            workflow.published_version === undefined ? (
              <Editor
                key={workflow.version}
                initial={workflow}
                base={blank(workflow)}
              />
            ) : (
              <EditorFromVersion
                key={workflow.version}
                workflow={workflow}
              />
            )
          ) : (
            <Editor
              key={workflow.version}
              initial={workflow}
              base={workflow.draft as unknown as Definition}
            />
          )
        }
      </Loadable>
    </section>
  );
}
