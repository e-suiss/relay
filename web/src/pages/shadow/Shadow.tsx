import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation, usePaged } from "../../api/hooks";
import type {
  ShadowCoverage,
  ShadowCoverageRow,
  ShadowDifference,
  ShadowLayer,
} from "../../api/pending";
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
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { problemText, useStepUp } from "../../session/stepUp";
import {
  combination,
  criteria,
  expiresSoon,
  expiryAfter,
  maxExpiryDays,
  needsAttention,
  orderRows,
  rowOrders,
  validDays,
  type RowOrder,
} from "./coverage";

const layers: readonly ShadowLayer[] = ["decision", "content", "routing"];

function Verdict({ met, label }: { met: boolean; label: string }) {
  return (
    <span
      className={`badge tone-${met ? "ok" : "bad"}`}
      data-shadow-met={met ? "true" : "false"}
    >
      <span aria-hidden="true">{met ? "✓" : "✕"}</span>
      <span className="badge-label">{label}</span>
    </span>
  );
}

// OP-52
export function ShadowScopeNotice() {
  const { t } = useI18n();
  return (
    <p className="notice" role="note">
      {t("shadow.measures")}
    </p>
  );
}

// OP-52
// OP-79
// OP-94
export function CoverageSummary({ coverage }: { coverage: ShadowCoverage }) {
  const { t } = useI18n();
  const met = criteria(coverage);
  const items = [
    {
      key: "combinations",
      met: met.combinations,
      text: t("shadow.criterion.combinations", {
        sufficient: met.sufficient,
        total: met.total,
      }),
    },
    {
      key: "days",
      met: met.days,
      text: t("shadow.criterion.days", {
        window: coverage.window_days,
        days: coverage.days_observed,
      }),
    },
    {
      key: "unexplained",
      met: met.unexplained,
      text: t("shadow.criterion.unexplained", {
        count: coverage.unexplained_decision_differences,
      }),
    },
  ];
  return (
    <div className="panel stack">
      <p>
        <Verdict
          met={coverage.exit_criteria_met}
          label={t(
            coverage.exit_criteria_met ? "shadow.exitMet" : "shadow.exitNotMet",
          )}
        />
      </p>
      <h3>{t("shadow.criteria")}</h3>
      <ul className="plain stack">
        {items.map((item) => (
          <li key={item.key} className="row" data-criterion={item.key}>
            <Verdict
              met={item.met}
              label={t(item.met ? "shadow.met" : "shadow.notMet")}
            />
            <span>{item.text}</span>
          </li>
        ))}
      </ul>
      <KeyValues
        items={[
          [t("shadow.window"), coverage.window_days],
          [
            t("shadow.firstObserved"),
            <Time value={coverage.first_observed_at} />,
          ],
          [t("shadow.daysObserved"), coverage.days_observed],
          [
            t("shadow.unexplainedTotal"),
            coverage.unexplained_decision_differences,
          ],
          [
            t("shadow.activeDifferences"),
            coverage.active_intentional_differences,
          ],
        ]}
      />
    </div>
  );
}

function RowFlags({ row }: { row: ShadowCoverageRow }) {
  const { t } = useI18n();
  if (!needsAttention(row))
    return (
      <span className="badge tone-ok" data-shadow-flag="sufficient">
        <span aria-hidden="true">✓</span>
        <span className="badge-label">{t("shadow.flag.sufficient")}</span>
      </span>
    );
  return (
    <span className="row">
      {!row.sufficient && (
        <span className="badge tone-warn" data-shadow-flag="insufficient">
          <span aria-hidden="true">!</span>
          <span className="badge-label">{t("shadow.flag.insufficient")}</span>
        </span>
      )}
      {row.unexplained > 0 && (
        <span className="badge tone-bad" data-shadow-flag="unexplained">
          <span aria-hidden="true">✕</span>
          <span className="badge-label">{t("shadow.flag.unexplained")}</span>
        </span>
      )}
    </span>
  );
}

function CoverageRows({ rows }: { rows: readonly ShadowCoverageRow[] }) {
  const { t } = useI18n();
  const orderId = useId();
  const [order, setOrder] = useState<RowOrder>("received");
  const attention = rows.filter(needsAttention).length;
  const columns: Column<ShadowCoverageRow>[] = [
    {
      key: "flags",
      header: t("status.label"),
      render: (row) => <RowFlags row={row} />,
    },
    {
      key: "template",
      header: t("shadow.template"),
      render: (row) => <Mono>{row.template}</Mono>,
    },
    {
      key: "locale",
      header: t("shadow.locale"),
      render: (row) => <Mono>{row.locale}</Mono>,
    },
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    {
      key: "observed",
      header: t("shadow.observed"),
      render: (row) => row.observed,
    },
    {
      key: "decision",
      header: t("shadow.decisionDifferences"),
      render: (row) => row.decision_differences,
    },
    {
      key: "explained",
      header: t("shadow.explained"),
      render: (row) => row.explained,
    },
    {
      key: "unexplained",
      header: t("shadow.unexplained"),
      render: (row) =>
        row.unexplained > 0 ? <strong>{row.unexplained}</strong> : 0,
    },
    {
      key: "content",
      header: t("shadow.contentDifferences"),
      render: (row) => row.content_differences,
    },
    {
      key: "routing",
      header: t("shadow.routingDifferences"),
      render: (row) => row.routing_differences,
    },
  ];
  return (
    <>
      <div className="row filters">
        <div className="field">
          <label htmlFor={orderId}>{t("shadow.order")}</label>
          <select
            id={orderId}
            value={order}
            onChange={(event) => {
              setOrder(event.target.value as RowOrder);
            }}
          >
            {rowOrders.map((item) => (
              <option key={item} value={item}>
                {t(`shadow.order.${item}`)}
              </option>
            ))}
          </select>
        </div>
      </div>
      {attention > 0 && (
        <p className="muted">{t("shadow.attention", { count: attention })}</p>
      )}
      <DataTable
        caption={t("shadow.rows")}
        columns={columns}
        rows={orderRows(rows, order)}
        rowKey={combination}
      />
    </>
  );
}

function optional(value: string): string | null {
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

// OP-79
// OP-94
function DifferenceForm({ onDone }: { onDone: () => void }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const ids = {
    layer: useId(),
    field: useId(),
    template: useId(),
    channel: useId(),
    owner: useId(),
    reason: useId(),
    days: useId(),
  };
  const [layer, setLayer] = useState<ShadowLayer>("decision");
  const [field, setField] = useState("");
  const [template, setTemplate] = useState("");
  const [channel, setChannel] = useState("");
  const [owner, setOwner] = useState("");
  const [reason, setReason] = useState("");
  const [days, setDays] = useState(String(maxExpiryDays));
  const [key, setKey] = useState(idempotencyKey);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const daysValid = validDays(Number(days));

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!daysValid) return;
    const body = {
      layer,
      field: optional(field),
      template: optional(template),
      channel: optional(channel),
      owner: owner.trim(),
      reason: reason.trim(),
      expires_at: expiryAfter(new Date(), Number(days)),
    };
    setBusy(true);
    setError(null);
    mutate<ShadowDifference>("POST", "/v1/shadow/differences", body, key).then(
      () => {
        setBusy(false);
        setField("");
        setTemplate("");
        setChannel("");
        setReason("");
        setKey(idempotencyKey());
        onDone();
      },
      (failure: unknown) => {
        setBusy(false);
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };

  return (
    <form className="panel stack" onSubmit={submit}>
      <div className="row filters">
        <div className="field">
          <label htmlFor={ids.layer}>{t("shadow.layer")}</label>
          <select
            id={ids.layer}
            value={layer}
            onChange={(event) => {
              setLayer(event.target.value as ShadowLayer);
            }}
          >
            {layers.map((item) => (
              <option key={item} value={item}>
                {t(`shadow.layer.${item}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.field}>{t("shadow.field")}</label>
          <input
            id={ids.field}
            value={field}
            placeholder={t("common.all")}
            onChange={(event) => {
              setField(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.template}>{t("shadow.template")}</label>
          <input
            id={ids.template}
            value={template}
            placeholder={t("common.all")}
            onChange={(event) => {
              setTemplate(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.channel}>{t("why.channel")}</label>
          <input
            id={ids.channel}
            value={channel}
            placeholder={t("common.all")}
            onChange={(event) => {
              setChannel(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.owner}>{t("shadow.owner")}</label>
          <input
            id={ids.owner}
            required
            value={owner}
            onChange={(event) => {
              setOwner(event.target.value);
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.days}>{t("shadow.days")}</label>
          <input
            id={ids.days}
            type="number"
            min={1}
            max={maxExpiryDays}
            required
            value={days}
            aria-invalid={daysValid ? undefined : true}
            onChange={(event) => {
              setDays(event.target.value);
            }}
          />
        </div>
      </div>
      <div className="field">
        <label htmlFor={ids.reason}>{t("pii.reason")}</label>
        <input
          id={ids.reason}
          required
          value={reason}
          onChange={(event) => {
            setReason(event.target.value);
          }}
        />
      </div>
      {error && <p role="alert">{error}</p>}
      <span>
        <button
          type="submit"
          className="primary"
          disabled={
            busy || !daysValid || owner.trim() === "" || reason.trim() === ""
          }
        >
          {t("shadow.add")}
        </button>
      </span>
    </form>
  );
}

// OP-79
function RenewButton({
  row,
  onDone,
}: {
  row: ShadowDifference;
  onDone: () => void;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const reasonId = useId();
  const daysId = useId();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [days, setDays] = useState(String(maxExpiryDays));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [key, setKey] = useState(idempotencyKey);
  const daysValid = validDays(Number(days));

  if (!open)
    return (
      <button
        type="button"
        onClick={() => {
          setOpen(true);
        }}
      >
        {t("shadow.renew")}
      </button>
    );

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!daysValid) return;
    const path = `/v1/shadow/differences/${encodeURIComponent(row.id)}/renew`;
    const body = {
      expires_at: expiryAfter(new Date(), Number(days)),
      reason: reason.trim(),
    };
    setBusy(true);
    setError(null);
    mutate<ShadowDifference>("POST", path, body, key).then(
      () => {
        setBusy(false);
        setOpen(false);
        setReason("");
        setKey(idempotencyKey());
        onDone();
      },
      (failure: unknown) => {
        setBusy(false);
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };

  return (
    <form className="stack" onSubmit={submit}>
      <label htmlFor={daysId}>{t("shadow.days")}</label>
      <input
        id={daysId}
        type="number"
        min={1}
        max={maxExpiryDays}
        required
        value={days}
        aria-invalid={daysValid ? undefined : true}
        onChange={(event) => {
          setDays(event.target.value);
        }}
      />
      <label htmlFor={reasonId}>{t("pii.reason")}</label>
      <input
        id={reasonId}
        required
        value={reason}
        onChange={(event) => {
          setReason(event.target.value);
        }}
      />
      <p className="muted small">{t("shadow.renewNote")}</p>
      {error && <p role="alert">{error}</p>}
      <span className="row">
        <button
          type="submit"
          className="primary"
          disabled={busy || !daysValid || reason.trim() === ""}
        >
          {t("shadow.renew")}
        </button>
        <button
          type="button"
          onClick={() => {
            setOpen(false);
          }}
        >
          {t("pii.cancel")}
        </button>
      </span>
    </form>
  );
}

function DifferenceState({ row }: { row: ShadowDifference }) {
  const { t } = useI18n();
  const active = row.state === "active";
  return (
    <span
      className={`badge tone-${active ? "info" : "neutral"}`}
      data-shadow-state={row.state}
    >
      <span aria-hidden="true">{active ? "●" : "○"}</span>
      <span className="badge-label">{t(`shadow.state.${row.state}`)}</span>
    </span>
  );
}

function Expiry({ row, now }: { row: ShadowDifference; now: Date }) {
  const { t } = useI18n();
  return (
    <span className="stack">
      <Time value={row.expires_at} />
      {row.state === "active" && expiresSoon(row.expires_at, now) && (
        <span className="badge tone-warn" data-shadow-soon="true">
          <span aria-hidden="true">⌛</span>
          <span className="badge-label">{t("shadow.expiresSoon")}</span>
        </span>
      )}
    </span>
  );
}

function scopeParts(row: ShadowDifference): string[] {
  return [row.template, row.channel, row.field].filter(
    (part): part is string => part !== null && part !== "",
  );
}

// OP-52
// OP-79
// OP-94
export function Shadow() {
  const { t } = useI18n();
  const [now] = useState(() => new Date());
  const coverage = useGet<ShadowCoverage>("/v1/shadow/coverage");
  const differences = usePaged<ShadowDifference>("/v1/shadow/differences");
  const refresh = () => {
    differences.reload();
    coverage.reload();
  };

  const columns: Column<ShadowDifference>[] = [
    {
      key: "state",
      header: t("status.label"),
      render: (row) => <DifferenceState row={row} />,
    },
    {
      key: "layer",
      header: t("shadow.layer"),
      render: (row) => t(`shadow.layer.${row.layer}`),
    },
    {
      key: "scope",
      header: t("shadow.scope"),
      render: (row) => {
        const parts = scopeParts(row);
        return parts.length === 0 ? (
          t("shadow.scopeAll")
        ) : (
          <Mono>{parts.join(" · ")}</Mono>
        );
      },
    },
    { key: "owner", header: t("shadow.owner"), render: (row) => row.owner },
    { key: "reason", header: t("pii.reason"), render: (row) => row.reason },
    {
      key: "expires",
      header: t("shadow.expires"),
      render: (row) => <Expiry row={row} now={now} />,
    },
    {
      key: "renewals",
      header: t("shadow.renewals"),
      render: (row) => row.renewals,
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (row) => <RenewButton row={row} onDone={refresh} />,
    },
  ];

  return (
    <section className="stack">
      <h1>{t("nav.shadow")}</h1>
      <p className="muted">{t("shadow.intro")}</p>
      <ShadowScopeNotice />
      <Section title={t("shadow.coverage")}>
        <Loadable state={coverage.state} onRetry={coverage.reload}>
          {(data) => (
            <>
              <CoverageSummary coverage={data} />
              <h3>{t("shadow.rows")}</h3>
              <CoverageRows rows={data.rows} />
            </>
          )}
        </Loadable>
      </Section>
      <Section title={t("shadow.differences")}>
        <p className="muted">{t("shadow.differencesIntro")}</p>
        <Loadable state={differences.state} onRetry={differences.reload}>
          {() => (
            <DataTable
              caption={t("shadow.differences")}
              columns={columns}
              rows={differences.items}
              rowKey={(row) => row.id}
            />
          )}
        </Loadable>
        <Pager
          hasPrevious={differences.hasPrevious}
          hasNext={differences.hasNext}
          onPrevious={differences.previous}
          onNext={differences.next}
        />
      </Section>
      <Section title={t("shadow.addTitle")}>
        <DifferenceForm onDone={refresh} />
      </Section>
    </section>
  );
}
