import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation, usePaged } from "../../api/hooks";
import type { Page, ServerSchemas, Topic } from "../../api/types";
import {
  DataTable,
  Loadable,
  Mono,
  Pager,
  Time,
  type Column,
} from "../../components/data";
import { useI18n } from "../../i18n/i18n";
import { problemText, useStepUp } from "../../session/stepUp";

type Agent = ServerSchemas["Agent"];
type CeilingHold = ServerSchemas["CeilingHold"];
type CeilingDecision = ServerSchemas["CeilingDecision"];
type Decision = CeilingDecision["decision"];

// AG-49
export function Agents() {
  const { t } = useI18n();
  const paged = usePaged<Agent>("/v1/agents");
  const columns: Column<Agent>[] = [
    { key: "name", header: t("agents.name"), render: (row) => row.name },
    { key: "id", header: "ID", render: (row) => <Mono>{row.id}</Mono> },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "mailbox",
      header: t("agents.mailbox"),
      render: (row) => (
        <span>
          {t(`agents.mailboxState.${row.mailbox.state}`)}{" "}
          <Mono>{row.mailbox.id}</Mono>
        </span>
      ),
    },
    {
      key: "endpoints",
      header: t("agents.endpoints"),
      render: (row) =>
        [
          row.endpoints.webhook_endpoint_id ? "webhook" : null,
          row.endpoints.a2a_push_endpoint_id ? "A2A" : null,
          row.endpoints.realtime ? "realtime" : null,
        ]
          .filter((item) => item !== null)
          .join(", ") || "—",
    },
    {
      key: "topics",
      header: t("nav.topics"),
      render: (row) => (row.topics.length === 0 ? "—" : row.topics.join(", ")),
    },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.agents")}</h1>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <DataTable
            caption={t("nav.agents")}
            columns={columns}
            rows={paged.items}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </section>
  );
}

const decisions: readonly Decision[] = ["send_all", "cancel", "stop"];

function CeilingDecisionForm({
  agent,
  ceilingEventId,
  onDone,
}: {
  agent: Agent;
  ceilingEventId: string;
  onDone: (message: string) => void;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const refId = useId();
  const noteId = useId();
  const [decisionRef, setDecisionRef] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const [pending, setPending] = useState<Decision | null>(null);

  const decide = (decision: Decision) => {
    setPending(decision);
    setError(null);
    const body: Record<string, unknown> = {
      decision,
      ceiling_event_id: ceilingEventId,
      decision_ref: decisionRef,
    };
    if (note !== "") body.note = note;
    mutate<CeilingDecision>(
      "POST",
      `/v1/agents/${encodeURIComponent(agent.id)}/ceiling_decisions`,
      body,
      key,
    ).then(
      (done) => {
        setPending(null);
        setKey(idempotencyKey());
        onDone(
          t("ceiling.applied", {
            count: done.applied_count,
            state: done.agent_state,
          }),
        );
      },
      (failure: unknown) => {
        setPending(null);
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
  };

  return (
    <form className="panel stack" onSubmit={submit}>
      <div className="row filters">
        <div className="field grow">
          <label htmlFor={refId}>{t("ceiling.decisionRef")}</label>
          <input
            id={refId}
            required
            value={decisionRef}
            onChange={(event) => {
              setDecisionRef(event.target.value);
            }}
          />
        </div>
        <div className="field grow">
          <label htmlFor={noteId}>{t("ceiling.note")}</label>
          <input
            id={noteId}
            value={note}
            onChange={(event) => {
              setNote(event.target.value);
            }}
          />
        </div>
      </div>
      <p className="muted small">{t("ceiling.stepUpNote")}</p>
      <div className="row">
        {decisions.map((decision) => (
          <button
            key={decision}
            type="button"
            className={decision === "send_all" ? "primary" : undefined}
            disabled={pending !== null || decisionRef.trim() === ""}
            onClick={() => {
              decide(decision);
            }}
          >
            {t(`ceiling.decision.${decision}`)}
          </button>
        ))}
      </div>
      {error && <p role="alert">{error}</p>}
    </form>
  );
}

function Holds({
  agent,
  onDecided,
}: {
  agent: Agent;
  onDecided: (message: string) => void;
}) {
  const { t } = useI18n();
  const holds = useGet<Page<CeilingHold>>(
    `/v1/agents/${encodeURIComponent(agent.id)}/ceiling_holds`,
    { state: "held", limit: 100 },
  );
  const columns: Column<CeilingHold>[] = [
    {
      key: "notification",
      header: t("activity.notification"),
      render: (row) => <Mono>{row.notification_id}</Mono>,
    },
    {
      key: "rule",
      header: "rule_id",
      render: (row) => <Mono>{row.rule_id}</Mono>,
    },
    {
      key: "held",
      header: t("ceiling.heldAt"),
      render: (row) => <Time value={row.held_at} />,
    },
    {
      key: "expires",
      header: t("killSwitch.expires"),
      render: (row) => <Time value={row.expires_at} />,
    },
  ];
  return (
    <Loadable state={holds.state} onRetry={holds.reload}>
      {(page) => {
        const events = [...new Set(page.data.map((row) => row.ceiling_event_id))];
        return (
          <div className="stack">
            <DataTable
              caption={t("ceiling.held", { agent: agent.name })}
              columns={columns}
              rows={page.data}
              rowKey={(row) => row.notification_id}
            />
            {events.map((event) => (
              <CeilingDecisionForm
                key={event}
                agent={agent}
                ceilingEventId={event}
                onDone={(message) => {
                  onDecided(message);
                  holds.reload();
                }}
              />
            ))}
          </div>
        );
      }}
    </Loadable>
  );
}

function AgentHolds({ agent }: { agent: Agent }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  return (
    <li className="panel stack">
      <div className="row">
        <strong>{agent.name}</strong>
        <Mono>{agent.id}</Mono>
        <span className="muted">{agent.state}</span>
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("ceiling.hide") : t("ceiling.show")}
        </button>
      </div>
      {message && <p role="status">{message}</p>}
      {open && <Holds agent={agent} onDecided={setMessage} />}
    </li>
  );
}

// AG-54
export function AgentCeiling() {
  const { t } = useI18n();
  const paged = usePaged<Agent>("/v1/agents");
  return (
    <section className="stack">
      <h1>{t("nav.ceiling")}</h1>
      <p className="muted">{t("ceiling.intro")}</p>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() =>
          paged.items.length === 0 ? (
            <p className="muted">{t("common.empty")}</p>
          ) : (
            <ul className="plain stack">
              {paged.items.map((agent) => (
                <AgentHolds key={agent.id} agent={agent} />
              ))}
            </ul>
          )
        }
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </section>
  );
}

export function Topics() {
  const { t } = useI18n();
  const paged = usePaged<Topic>("/v1/topics");
  const columns: Column<Topic>[] = [
    { key: "key", header: t("topics.key"), render: (row) => <Mono>{row.key}</Mono> },
    {
      key: "parent",
      header: t("topics.parent"),
      render: (row) => (row.parent ? <Mono>{row.parent}</Mono> : "—"),
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.topics")}</h1>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <DataTable
            caption={t("nav.topics")}
            columns={columns}
            rows={paged.items}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </section>
  );
}
