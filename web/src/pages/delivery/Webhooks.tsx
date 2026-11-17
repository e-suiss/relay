import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation } from "../../api/hooks";
import type { ServerSchemas } from "../../api/types";
import {
  KeyValues,
  Loadable,
  Mono,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { useI18n } from "../../i18n/i18n";
import { problemText, useStepUp } from "../../session/stepUp";

type Endpoint = ServerSchemas["WebhookEndpoint"];
type Health = ServerSchemas["WebhookEndpointHealth"];
type Message = ServerSchemas["WebhookMessage"];

// WH-39
function EndpointHealth({ endpoint }: { endpoint: Endpoint }) {
  const { t } = useI18n();
  const health = useGet<Health>(
    `/v1/webhook_endpoints/${encodeURIComponent(endpoint.id)}/health`,
  );
  return (
    <Loadable state={health.state} onRetry={health.reload}>
      {(data) => (
        <KeyValues
          items={[
            [t("activity.state"), data.state],
            [t("webhooks.window"), data.window],
            [t("webhooks.succeeded"), data.succeeded],
            [t("webhooks.failed"), data.failed],
            [
              t("webhooks.successRate"),
              data.success_rate_bp === null
                ? "—"
                : `${(data.success_rate_bp / 100).toFixed(2)}%`,
            ],
            [
              t("webhooks.latency"),
              data.latency_ms
                ? `p50 ${data.latency_ms.p50} · p95 ${data.latency_ms.p95} · p99 ${data.latency_ms.p99} ms`
                : "—",
            ],
            [t("webhooks.breaker"), t(`channels.breaker.${data.breaker.state}`)],
            [
              t("webhooks.backlog"),
              `${data.backlog.waiting} / ${data.backlog.held}`,
            ],
            [t("webhooks.failingSince"), <Time key="f" value={data.failing_since} />],
            [t("webhooks.disableAt"), <Time key="d" value={data.disable_at} />],
          ]}
        />
      )}
    </Loadable>
  );
}

// WH-46
function Replay({ endpoint }: { endpoint: Endpoint }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const sinceId = useId();
  const [since, setSince] = useState("");
  const [result, setResult] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    const at = new Date(since);
    if (Number.isNaN(at.getTime())) return;
    mutate<unknown>(
      "POST",
      `/v1/webhook_endpoints/${encodeURIComponent(endpoint.id)}/replay`,
      { since: at.toISOString() },
      key,
    ).then(
      () => {
        setKey(idempotencyKey());
        setResult(t("webhooks.replayed"));
      },
      (failure: unknown) => {
        if (!stepUp(failure)) setResult(problemText(failure));
      },
    );
  };
  return (
    <form className="row filters" onSubmit={submit}>
      <div className="field">
        <label htmlFor={sinceId}>{t("webhooks.replaySince")}</label>
        <input
          id={sinceId}
          type="datetime-local"
          required
          value={since}
          onChange={(event) => {
            setSince(event.target.value);
          }}
        />
      </div>
      <button type="submit">{t("webhooks.replay")}</button>
      {result && <span role="status">{result}</span>}
    </form>
  );
}

function EndpointRow({ endpoint }: { endpoint: Endpoint }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <li className="panel stack" data-endpoint={endpoint.id}>
      <div className="row">
        <Mono>{endpoint.id}</Mono>
        <span>{endpoint.use}</span>
        <span>{endpoint.state}</span>
        {endpoint.disabled_reason && <code>{endpoint.disabled_reason}</code>}
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("webhooks.hideHealth") : t("webhooks.showHealth")}
        </button>
      </div>
      {endpoint.description && <p className="muted">{endpoint.description}</p>}
      {open && (
        <>
          <EndpointHealth endpoint={endpoint} />
          <Replay endpoint={endpoint} />
        </>
      )}
    </li>
  );
}

function Resend({ message }: { message: Message }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const [key] = useState(idempotencyKey);
  const [done, setDone] = useState<string | null>(null);
  if (done) return <span role="status">{done}</span>;
  return (
    <button
      type="button"
      onClick={() => {
        mutate<Message>(
          "POST",
          `/v1/webhook_messages/${encodeURIComponent(message.id)}/resend`,
          {},
          key,
        ).then(
          () => {
            setDone(t("webhooks.resent"));
          },
          (failure: unknown) => {
            setDone(problemText(failure));
          },
        );
      }}
    >
      {t("webhooks.resend")}
    </button>
  );
}

const finalStates: readonly Message["state"][] = [
  "failed_permanent",
  "exhausted",
  "expired",
  "window_exceeded",
  "dead_lettered",
];

// WH-39
// WH-46
export function Webhooks() {
  const { t } = useI18n();
  const stateId = useId();
  const [state, setState] = useState("");
  const messages: Column<Message>[] = [
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => <Time value={row.created_at} />,
    },
    { key: "type", header: t("history.event"), render: (row) => row.event_type },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    { key: "attempts", header: t("history.attempts"), render: (row) => row.attempt_count },
    {
      key: "status",
      header: t("webhooks.lastStatus"),
      render: (row) =>
        row.last_response_status === null ? "—" : row.last_response_status,
    },
    {
      key: "reason",
      header: t("reports.reason"),
      render: (row) => (row.reason ? <code>{row.reason}</code> : "—"),
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (row) => (finalStates.includes(row.state) ? <Resend message={row} /> : "—"),
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.webhooks")}</h1>
      <PagedTable<Endpoint>
        title={t("webhooks.endpoints")}
        path="/v1/webhook_endpoints"
        columns={[]}
        rowKey={(row) => row.id}
        after={(rows) => (
          <ul className="plain stack">
            {rows.map((endpoint) => (
              <EndpointRow key={endpoint.id} endpoint={endpoint} />
            ))}
          </ul>
        )}
      />
      <div className="row filters">
        <div className="field">
          <label htmlFor={stateId}>{t("webhooks.logState")}</label>
          <select
            id={stateId}
            value={state}
            onChange={(event) => {
              setState(event.target.value);
            }}
          >
            <option value="">{t("common.all")}</option>
            <option value="dead_lettered">{t("webhooks.deadLetters")}</option>
            <option value="delivered">delivered</option>
            <option value="scheduled">scheduled</option>
            <option value="held">held</option>
            <option value="exhausted">exhausted</option>
          </select>
        </div>
      </div>
      <PagedTable
        title={t("webhooks.log")}
        path="/v1/webhook_messages"
        query={{ state }}
        columns={messages}
        rowKey={(row) => row.id}
      />
    </section>
  );
}
