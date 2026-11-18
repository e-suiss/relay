import { useId, useState } from "react";
import { usePaged } from "../../api/hooks";
import type { ServerSchemas } from "../../api/types";
import {
  DataTable,
  KeyValues,
  Loadable,
  Mono,
  Pager,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { useI18n } from "../../i18n/i18n";

type Waitpoint = ServerSchemas["Waitpoint"];
type EvidenceLevel = ServerSchemas["EvidenceLevel"];

const levels: readonly EvidenceLevel[] = [
  "channel_claim",
  "relay_session",
  "access_aas_ref",
];

export interface WaitpointSummary {
  total: number;
  open: number;
  stalled: number;
  resolved: number;
  withEscalation: number;
  evidence: Record<EvidenceLevel, number>;
}

// AG-49
/** Counts of the waiting requests shown on the page; the API reports no installation-wide aggregate. */
export function summarize(rows: readonly Waitpoint[]): WaitpointSummary {
  const evidence = Object.fromEntries(
    levels.map((level) => [level, 0]),
  ) as Record<EvidenceLevel, number>;
  let withEscalation = 0;
  for (const row of rows) {
    const level = row.response?.evidence_level;
    if (level) evidence[level] += 1;
    if (row.state === "resolved" && row.escalation_policy) withEscalation += 1;
  }
  return {
    total: rows.length,
    open: rows.filter((row) => row.state === "open").length,
    stalled: rows.filter((row) => row.state === "stalled").length,
    resolved: rows.filter((row) => row.state === "resolved").length,
    withEscalation,
    evidence,
  };
}

// AG-49
// AG-54
export function Waitpoints() {
  const { t } = useI18n();
  const stateId = useId();
  const [state, setState] = useState("open");
  const paged = usePaged<Waitpoint>("/v1/waitpoints", { state });

  const columns: Column<Waitpoint>[] = [
    {
      key: "id",
      header: t("waitpoints.request"),
      render: (row) => <Mono>{row.id}</Mono>,
    },
    { key: "kind", header: t("waitpoints.kind"), render: (row) => row.kind },
    {
      key: "state",
      header: t("status.label"),
      render: (row) => t(`waitpoints.state.${row.state}`),
    },
    {
      key: "waiter",
      header: t("waitpoints.waiter"),
      render: (row) => (
        <span>
          {row.waiter.kind} <Mono>{row.waiter.id}</Mono>
        </span>
      ),
    },
    {
      key: "escalation",
      header: t("waitpoints.escalation"),
      render: (row) =>
        row.escalation_policy ? (
          <Mono>
            {row.escalation_policy.key ?? t("waitpoints.inline")} v
            {row.escalation_policy.version}
          </Mono>
        ) : (
          "—"
        ),
    },
    {
      key: "evidence",
      header: t("waitpoints.evidence"),
      render: (row) =>
        row.response
          ? t(`waitpoints.level.${row.response.evidence_level}`)
          : "—",
    },
    {
      key: "expires",
      header: t("killSwitch.expires"),
      render: (row) => <Time value={row.expires_at} />,
    },
    {
      key: "heartbeat",
      header: t("waitpoints.heartbeat"),
      render: (row) => <Time value={row.heartbeat_due_at} />,
    },
  ];

  return (
    <section className="stack">
      <h1>{t("nav.waitpoints")}</h1>
      <div className="row filters">
        <div className="field">
          <label htmlFor={stateId}>{t("status.label")}</label>
          <select
            id={stateId}
            value={state}
            onChange={(event) => {
              setState(event.target.value);
            }}
          >
            {(
              ["open", "stalled", "resolved", "expired", "cancelled"] as const
            ).map((value) => (
              <option key={value} value={value}>
                {t(`waitpoints.state.${value}`)}
              </option>
            ))}
          </select>
        </div>
      </div>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => {
          const summary = summarize(paged.items);
          return (
            <>
              <Section title={t("waitpoints.summary")}>
                <p className="muted small">{t("waitpoints.summaryNote")}</p>
                <KeyValues
                  items={[
                    [t("waitpoints.shown"), summary.total],
                    [
                      t("waitpoints.resolvedByEscalation"),
                      summary.withEscalation,
                    ],
                    ...levels.map(
                      (level) =>
                        [
                          t(`waitpoints.level.${level}`),
                          summary.evidence[level],
                        ] as const,
                    ),
                  ]}
                />
              </Section>
              <DataTable
                caption={t("nav.waitpoints")}
                columns={columns}
                rows={paged.items}
                rowKey={(row) => row.id}
              />
            </>
          );
        }}
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
