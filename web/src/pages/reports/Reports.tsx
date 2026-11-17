import { useId, useState } from "react";
import { useGet } from "../../api/hooks";
import type { ServerSchemas } from "../../api/types";
import {
  DataTable,
  Loadable,
  Mono,
  Section,
  type Column,
} from "../../components/data";
import {
  ChannelLabel,
  ClickSplit,
  OpenTrackingNotice,
} from "../../components/status";
import { useI18n } from "../../i18n/i18n";

type DeliveryRow = ServerSchemas["DeliveryReportRow"];
type SkipRow = ServerSchemas["SkipReportRow"];
type CostRow = ServerSchemas["CostReportRow"];
type DeliveryReport = ServerSchemas["DeliveryReport"];
type SkipReport = ServerSchemas["SkipReport"];
type CostReport = ServerSchemas["CostReport"];

const funnelSteps = [
  "accepted",
  "enqueued",
  "dispatched",
  "provider_accepted",
  "delivered",
  "engaged",
] as const;

type FunnelStep = (typeof funnelSteps)[number];

export function sum<T>(rows: readonly T[], pick: (row: T) => number): number {
  return rows.reduce((total, row) => total + pick(row), 0);
}

export function rate(part: number, whole: number): string {
  if (whole === 0) return "—";
  return `${((part / whole) * 100).toFixed(1)}%`;
}

interface Group {
  key: string;
  channel: DeliveryRow["channel"];
  provider: string | null;
  rows: DeliveryRow[];
}

export function byChannelProvider(rows: readonly DeliveryRow[]): Group[] {
  const groups = new Map<string, Group>();
  for (const row of rows) {
    const key = `${row.channel}/${row.provider ?? ""}`;
    const group = groups.get(key) ?? {
      key,
      channel: row.channel,
      provider: row.provider,
      rows: [],
    };
    group.rows.push(row);
    groups.set(key, group);
  }
  return [...groups.values()].sort((a, b) => a.key.localeCompare(b.key));
}

function isoDay(offset: number): string {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
}

// X-6
// DS-13
// DS-32
function Funnel({ rows }: { rows: DeliveryRow[] }) {
  const { t } = useI18n();
  const totals = Object.fromEntries(
    funnelSteps.map((step) => [step, sum(rows, (row) => row[step])]),
  ) as Record<FunnelStep, number>;
  const push = rows.filter(
    (row) => row.channel === "push" || row.channel === "web_push",
  );
  return (
    <Section title={t("reports.funnel")}>
      <ol className="funnel plain">
        {funnelSteps.map((step) => (
          <li key={step} className="row">
            <span className="funnel-label">{t(`reports.step.${step}`)}</span>
            <strong>{totals[step]}</strong>
            <span className="muted">{rate(totals[step], totals.accepted)}</span>
          </li>
        ))}
      </ol>
      {push.length > 0 && (
        <p className="muted">
          {t("reports.pushSplit", {
            accepted: rate(
              sum(push, (row) => row.provider_accepted),
              sum(push, (row) => row.dispatched),
            ),
            receipts: rate(
              sum(push, (row) => row.sdk_receipts),
              sum(push, (row) => row.dispatched),
            ),
          })}
        </p>
      )}
      <div className="row">
        <span>{t("engagement.clicks")}:</span>
        <ClickSplit
          human={sum(rows, (row) => row.human_clicks)}
          bot={sum(rows, (row) => row.bot_clicks)}
        />
      </div>
      {sum(rows, (row) => row.opens) > 0 && (
        <>
          <OpenTrackingNotice />
          <p className="muted">
            {t("reports.opens", {
              opens: sum(rows, (row) => row.opens),
              machine: sum(rows, (row) => row.machine_opens),
            })}
          </p>
        </>
      )}
    </Section>
  );
}

function Rates({ rows }: { rows: DeliveryRow[] }) {
  const { t } = useI18n();
  const columns: Column<Group>[] = [
    {
      key: "channel",
      header: t("why.channel"),
      render: (group) => <ChannelLabel channel={group.channel} />,
    },
    {
      key: "provider",
      header: t("history.provider"),
      render: (group) => group.provider ?? "—",
    },
    {
      key: "dispatched",
      header: t("reports.step.dispatched"),
      render: (group) => sum(group.rows, (row) => row.dispatched),
    },
    {
      key: "accepted",
      header: t("reports.providerRate"),
      render: (group) =>
        rate(
          sum(group.rows, (row) => row.provider_accepted),
          sum(group.rows, (row) => row.dispatched),
        ),
    },
    {
      key: "delivered",
      header: t("reports.deliveredRate"),
      render: (group) =>
        group.channel === "push" || group.channel === "web_push"
          ? t("reports.sdkReceipts", {
              rate: rate(
                sum(group.rows, (row) => row.sdk_receipts),
                sum(group.rows, (row) => row.dispatched),
              ),
            })
          : rate(
              sum(group.rows, (row) => row.delivered),
              sum(group.rows, (row) => row.dispatched),
            ),
    },
    {
      key: "failed",
      header: t("status.failed"),
      render: (group) => sum(group.rows, (row) => row.failed),
    },
    {
      key: "uncertain",
      header: t("status.unknown"),
      render: (group) => sum(group.rows, (row) => row.uncertain),
    },
    {
      key: "skipped",
      header: t("status.skipped"),
      render: (group) => sum(group.rows, (row) => row.skipped),
    },
    {
      key: "clicks",
      header: t("engagement.clicks"),
      render: (group) => (
        <ClickSplit
          human={sum(group.rows, (row) => row.human_clicks)}
          bot={sum(group.rows, (row) => row.bot_clicks)}
        />
      ),
    },
  ];
  return (
    <Section title={t("reports.rates")}>
      <DataTable
        caption={t("reports.rates")}
        columns={columns}
        rows={byChannelProvider(rows)}
        rowKey={(group) => group.key}
      />
    </Section>
  );
}

// X-1
function Skips({ rows }: { rows: SkipRow[] }) {
  const { t } = useI18n();
  const merged = new Map<string, SkipRow & { total: number }>();
  for (const row of rows) {
    const key = `${row.rule_id}/${row.channel}`;
    const entry = merged.get(key) ?? { ...row, total: 0 };
    entry.total += row.skipped;
    merged.set(key, entry);
  }
  const list = [...merged.values()].sort((a, b) => b.total - a.total);
  const columns: Column<(typeof list)[number]>[] = [
    {
      key: "rule",
      header: "rule_id",
      render: (row) => <Mono>{row.rule_id}</Mono>,
    },
    { key: "reason", header: t("reports.reason"), render: (row) => row.reason },
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    { key: "count", header: t("status.skipped"), render: (row) => row.total },
  ];
  return (
    <Section title={t("reports.skips")}>
      <DataTable
        caption={t("reports.skips")}
        columns={columns}
        rows={list}
        rowKey={(row) => `${row.rule_id}/${row.channel}`}
      />
    </Section>
  );
}

export function formatMicros(micros: string | null, currency: string | null) {
  if (micros === null || currency === null) return "—";
  const value = Number(micros) / 1_000_000;
  return `${value.toFixed(4)} ${currency}`;
}

// CH-18
function Costs({ rows }: { rows: CostRow[] }) {
  const { t } = useI18n();
  const columns: Column<CostRow>[] = [
    { key: "day", header: t("reports.day"), render: (row) => row.day },
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    {
      key: "provider",
      header: t("history.provider"),
      render: (row) => row.provider,
    },
    {
      key: "country",
      header: t("reports.country"),
      render: (row) => row.destination_country ?? "—",
    },
    {
      key: "outcome",
      header: t("history.outcome"),
      render: (row) => row.outcome,
    },
    {
      key: "units",
      header: t("reports.units"),
      render: (row) =>
        row.billable_units === null
          ? "—"
          : `${row.billable_units} ${row.billable_unit ?? ""}`,
    },
    {
      key: "cost",
      header: t("reports.cost"),
      render: (row) => formatMicros(row.cost_micros, row.currency),
    },
  ];
  return (
    <Section title={t("reports.costs")}>
      <DataTable
        caption={t("reports.costs")}
        columns={columns}
        rows={rows}
        rowKey={(row) =>
          `${row.day}/${row.channel}/${row.provider}/${row.destination_country ?? ""}/${row.outcome}/${String(row.is_test)}`
        }
      />
    </Section>
  );
}

// X-6
function NotReported() {
  const { t } = useI18n();
  return (
    <Section title={t("reports.more")}>
      <ul>
        <li>{t("reports.notReported.ab")}</li>
        <li>{t("reports.notReported.render")}</li>
        <li>{t("reports.notReported.fallbackTimezone")}</li>
      </ul>
    </Section>
  );
}

// X-1
// X-6
export function Reports() {
  const { t } = useI18n();
  const fromId = useId();
  const toId = useId();
  const planeId = useId();
  const [from, setFrom] = useState(isoDay(-29));
  const [to, setTo] = useState(isoDay(0));
  const [plane, setPlane] = useState<"live" | "test" | "all">("live");
  const range = { from, to };
  const deliveries = useGet<DeliveryReport>("/v1/reports/deliveries", range);
  const skips = useGet<SkipReport>("/v1/reports/skips", range);
  const costs = useGet<CostReport>("/v1/reports/costs", range);
  const keep = (row: { is_test: boolean }) =>
    plane === "all" || row.is_test === (plane === "test");

  return (
    <section className="stack">
      <h1>{t("nav.reports")}</h1>
      <div className="row filters">
        <div className="field">
          <label htmlFor={fromId}>{t("reports.from")}</label>
          <input
            id={fromId}
            type="date"
            value={from}
            onChange={(event) => {
              setFrom(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={toId}>{t("reports.to")}</label>
          <input
            id={toId}
            type="date"
            value={to}
            onChange={(event) => {
              setTo(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={planeId}>{t("activity.plane")}</label>
          <select
            id={planeId}
            value={plane}
            onChange={(event) => {
              setPlane(event.target.value as "live" | "test" | "all");
            }}
          >
            <option value="live">{t("activity.realSends")}</option>
            <option value="test">{t("activity.testSends")}</option>
            <option value="all">{t("common.all")}</option>
          </select>
        </div>
      </div>
      <Loadable state={deliveries.state} onRetry={deliveries.reload}>
        {(report) => {
          const rows = report.rows.filter(keep);
          return (
            <>
              <Funnel rows={rows} />
              <Rates rows={rows} />
            </>
          );
        }}
      </Loadable>
      <Loadable state={skips.state} onRetry={skips.reload}>
        {(report) => <Skips rows={report.rows.filter(keep)} />}
      </Loadable>
      <Loadable state={costs.state} onRetry={costs.reload}>
        {(report) => <Costs rows={report.rows.filter(keep)} />}
      </Loadable>
      <NotReported />
    </section>
  );
}
