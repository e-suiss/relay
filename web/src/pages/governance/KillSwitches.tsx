import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation, usePaged } from "../../api/hooks";
import type { Page, ServerSchemas } from "../../api/types";
import { Link } from "../../app/router";
import {
  DataTable,
  Dash,
  Loadable,
  Mono,
  Pager,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { useI18n } from "../../i18n/i18n";
import { useSession } from "../../session/session";
import { problemText, useStepUp } from "../../session/stepUp";

type KillSwitch = ServerSchemas["KillSwitch"];
type Engage = ServerSchemas["KillSwitchEngage"];

function scopeText(row: KillSwitch): string {
  return row.scope_ref ? `${row.scope_kind} ${row.scope_ref}` : row.scope_kind;
}

function targetText(row: KillSwitch): string {
  const target = row.target_ref
    ? `${row.target_kind} ${row.target_ref}`
    : row.target_kind;
  return row.channel ? `${row.channel} · ${target}` : target;
}

function KillSwitchState({ row }: { row: KillSwitch }) {
  const { t } = useI18n();
  const tone = row.state === "off" ? "bad" : row.state === "on" ? "ok" : "warn";
  return (
    <span className={`badge tone-${tone}`} data-kill-switch-state={row.state}>
      <span aria-hidden="true">{row.state === "off" ? "■" : "▶"}</span>
      <span className="badge-label">
        {t(`killSwitch.state.${row.state}`)}
        {row.state === "canary" && row.canary_percent !== null
          ? ` ${String(row.canary_percent ?? "")}%`
          : ""}
      </span>
    </span>
  );
}

// TN-41
// TN-44
// X-4
/** The active kill switches of the tenant context, on every console page. */
export function ActiveKillSwitches() {
  const { t } = useI18n();
  const { context } = useSession();
  const active = useGet<Page<KillSwitch>>(
    context.tenant === null ? null : "/v1/kill_switches",
    { limit: 20 },
  );
  if (active.state.kind !== "ready") return null;
  const rows = active.state.data.data.filter((row) => row.status === "active");
  return (
    <aside
      className={rows.length > 0 ? "kill-bar kill-bar-on" : "kill-bar"}
      aria-label={t("nav.killSwitches")}
    >
      {rows.length === 0 ? (
        <span className="muted">{t("killSwitch.none")}</span>
      ) : (
        <ul className="plain row">
          {rows.map((row) => (
            <li key={row.id} className="row">
              <KillSwitchState row={row} />
              <span>
                {scopeText(row)} × {targetText(row)} ×{" "}
                {row.message_class ?? t("killSwitch.allClasses")}
              </span>
            </li>
          ))}
        </ul>
      )}
      <Link to="/kill-switches">{t("killSwitch.manage")}</Link>
    </aside>
  );
}

const scopeKinds: readonly Engage["scope_kind"][] = [
  "tenant",
  "subtenant",
  "campaign",
  "workflow",
  "api_client",
  "sender",
];

function EngageForm({ onDone }: { onDone: () => void }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const ids = {
    scope: useId(),
    ref: useId(),
    channel: useId(),
    klass: useId(),
    reason: useId(),
    ttl: useId(),
  };
  const [scope, setScope] = useState<Engage["scope_kind"]>("workflow");
  const [ref, setRef] = useState("");
  const [channel, setChannel] = useState("");
  const [klass, setKlass] = useState("");
  const [reason, setReason] = useState("");
  const [ttl, setTtl] = useState("PT1H");
  const [key, setKey] = useState(idempotencyKey);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    const body: Record<string, unknown> = {
      scope_kind: scope,
      target_kind: "all",
      state: "off",
      reason,
      ttl,
    };
    if (ref !== "") body.scope_ref = ref;
    if (channel !== "") body.channel = channel;
    if (klass !== "") body.message_class = klass;
    setBusy(true);
    setError(null);
    mutate<KillSwitch>("POST", "/v1/kill_switches", body, key).then(
      () => {
        setBusy(false);
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
          <label htmlFor={ids.scope}>{t("killSwitch.scope")}</label>
          <select
            id={ids.scope}
            value={scope}
            onChange={(event) => {
              setScope(event.target.value as Engage["scope_kind"]);
            }}
          >
            {scopeKinds.map((kind) => (
              <option key={kind} value={kind}>
                {kind}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.ref}>{t("killSwitch.scopeRef")}</label>
          <input
            id={ids.ref}
            value={ref}
            onChange={(event) => {
              setRef(event.target.value.trim());
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
              setChannel(event.target.value.trim());
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.klass}>{t("activity.class")}</label>
          <input
            id={ids.klass}
            value={klass}
            placeholder={t("common.all")}
            onChange={(event) => {
              setKlass(event.target.value.trim());
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.ttl}>{t("killSwitch.ttl")}</label>
          <input
            id={ids.ttl}
            value={ttl}
            onChange={(event) => {
              setTtl(event.target.value.trim());
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
          disabled={busy || reason.trim() === ""}
        >
          {t("killSwitch.engage")}
        </button>
      </span>
    </form>
  );
}

export function ReleaseButton({
  path,
  onDone,
}: {
  path: string;
  onDone: () => void;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const reasonId = useId();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [key] = useState(idempotencyKey);

  if (!open)
    return (
      <button
        type="button"
        onClick={() => {
          setOpen(true);
        }}
      >
        {t("killSwitch.release")}
      </button>
    );

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    mutate<KillSwitch>("POST", path, { reason }, key).then(
      onDone,
      (failure: unknown) => {
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };

  return (
    <form className="stack" onSubmit={submit}>
      <label htmlFor={reasonId}>{t("pii.reason")}</label>
      <input
        id={reasonId}
        required
        value={reason}
        onChange={(event) => {
          setReason(event.target.value);
        }}
      />
      <p className="muted small">{t("killSwitch.stepUpNote")}</p>
      {error && <p role="alert">{error}</p>}
      <span className="row">
        <button type="submit" className="primary" disabled={reason === ""}>
          {t("killSwitch.release")}
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

// TN-41
// TN-44
export function KillSwitches() {
  const { t } = useI18n();
  const [released, setReleased] = useState(false);
  const releasedId = useId();
  const paged = usePaged<KillSwitch>("/v1/kill_switches", {
    include_released: released ? true : undefined,
  });

  const columns: Column<KillSwitch>[] = [
    {
      key: "state",
      header: t("status.label"),
      render: (row) => <KillSwitchState row={row} />,
    },
    {
      key: "scope",
      header: t("killSwitch.scope"),
      render: (row) => <Mono>{scopeText(row)}</Mono>,
    },
    {
      key: "target",
      header: t("killSwitch.target"),
      render: (row) => <Mono>{targetText(row)}</Mono>,
    },
    {
      key: "class",
      header: t("activity.class"),
      render: (row) => row.message_class ?? t("killSwitch.allClasses"),
    },
    { key: "reason", header: t("pii.reason"), render: (row) => row.reason },
    {
      key: "since",
      header: t("killSwitch.since"),
      render: (row) => <Time value={row.created_at} />,
    },
    {
      key: "expires",
      header: t("killSwitch.expires"),
      render: (row) => <Time value={row.expires_at} />,
    },
    {
      key: "by",
      header: t("audit.actor"),
      render: (row) => <Dash value={row.created_by} />,
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (row) =>
        row.status === "active" ? (
          <ReleaseButton
            path={`/v1/kill_switches/${encodeURIComponent(row.id)}/release`}
            onDone={paged.reload}
          />
        ) : (
          t("killSwitch.released")
        ),
    },
  ];

  return (
    <section className="stack">
      <h1>{t("nav.killSwitches")}</h1>
      <p className="muted">{t("killSwitch.effectNote")}</p>
      <Section title={t("killSwitch.engageTitle")}>
        <EngageForm onDone={paged.reload} />
      </Section>
      <Section title={t("killSwitch.list")}>
        <div className="row">
          <input
            id={releasedId}
            type="checkbox"
            checked={released}
            onChange={(event) => {
              setReleased(event.target.checked);
            }}
          />
          <label htmlFor={releasedId}>{t("killSwitch.showReleased")}</label>
        </div>
        <Loadable state={paged.state} onRetry={paged.reload}>
          {() => (
            <DataTable
              caption={t("killSwitch.list")}
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
      </Section>
    </section>
  );
}
