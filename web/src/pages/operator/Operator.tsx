import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation } from "../../api/hooks";
import type { RegionHealth } from "../../api/pending";
import type { OperatorSchemas, ServerSchemas } from "../../api/types";
import {
  KeyValues,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { useI18n } from "../../i18n/i18n";
import { ReleaseButton } from "../governance/KillSwitches";
import { problemText, useStepUp } from "../../session/stepUp";

type Tenant = OperatorSchemas["TenantOverview"];
type Critical = OperatorSchemas["CriticalInterruption"];
type KillSwitch = ServerSchemas["KillSwitch"];

function useAction() {
  const mutate = useMutation();
  const stepUp = useStepUp();
  return (
    path: string,
    body: unknown,
    key: string,
    done: () => void,
    fail: (text: string) => void,
  ) => {
    mutate<unknown>("POST", path, body, key).then(done, (failure: unknown) => {
      if (!stepUp(failure)) fail(problemText(failure));
    });
  };
}

function CriticalView({ tenant }: { tenant: Tenant }) {
  const { t } = useI18n();
  const critical = useGet<Critical>(
    `/v1/operator/tenants/${encodeURIComponent(tenant.id)}/critical_interruption`,
  );
  return (
    <Loadable state={critical.state} onRetry={critical.reload}>
      {(data) => (
        <KeyValues
          items={[
            [
              t("operator.critical"),
              data.enabled
                ? t("operator.criticalOpen")
                : t("operator.criticalClosed"),
            ],
            [
              t("operator.criticalTemplates"),
              data.templates.length === 0 ? "—" : data.templates.join(", "),
            ],
            [t("common.updated"), <Time key="u" value={data.updated_at} />],
          ]}
        />
      )}
    </Loadable>
  );
}

const grounds = ["abuse", "security", "legal", "other"] as const;

function TenantActions({
  tenant,
  onDone,
}: {
  tenant: Tenant;
  onDone: () => void;
}) {
  const { t } = useI18n();
  const act = useAction();
  const reasonId = useId();
  const groundId = useId();
  const [reason, setReason] = useState("");
  const [ground, setGround] = useState<(typeof grounds)[number]>("other");
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const suspended = tenant.status === "suspended";

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    const base = `/v1/operator/tenants/${encodeURIComponent(tenant.id)}`;
    act(
      suspended ? `${base}/resume` : `${base}/suspend`,
      suspended ? { reason } : { ground, reason },
      key,
      () => {
        setKey(idempotencyKey());
        setReason("");
        onDone();
      },
      setError,
    );
  };

  return (
    <form className="row filters" onSubmit={submit}>
      {!suspended && (
        <div className="field">
          <label htmlFor={groundId}>{t("operator.ground")}</label>
          <select
            id={groundId}
            value={ground}
            onChange={(event) => {
              setGround(event.target.value as (typeof grounds)[number]);
            }}
          >
            {grounds.map((item) => (
              <option key={item} value={item}>
                {item}
              </option>
            ))}
          </select>
        </div>
      )}
      <div className="field grow">
        <label htmlFor={reasonId}>{t("pii.reason")}</label>
        <input
          id={reasonId}
          required
          value={reason}
          onChange={(event) => {
            setReason(event.target.value);
          }}
        />
      </div>
      <button type="submit" disabled={reason.trim() === ""}>
        {suspended ? t("operator.resume") : t("operator.suspend")}
      </button>
      {error && <span role="alert">{error}</span>}
    </form>
  );
}

function TenantRow({ tenant, onDone }: { tenant: Tenant; onDone: () => void }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <li className="panel stack" data-tenant={tenant.id}>
      <div className="row">
        <Mono>{tenant.id}</Mono>
        <span>{tenant.region}</span>
        <span
          className={`badge tone-${tenant.status === "active" ? "ok" : "bad"}`}
        >
          <span className="badge-label">
            {t(`operator.status.${tenant.status}`)}
          </span>
        </span>
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("operator.hide") : t("operator.manage")}
        </button>
      </div>
      <KeyValues
        items={[
          [t("operator.notifications24h"), tenant.counters.notifications_24h],
          [t("operator.queued"), tenant.counters.queued_deliveries],
          [t("operator.paused"), tenant.counters.paused_deliveries],
          [t("operator.killSwitches"), tenant.counters.active_kill_switches],
        ]}
      />
      {open && (
        <>
          <CriticalView tenant={tenant} />
          <TenantActions tenant={tenant} onDone={onDone} />
        </>
      )}
    </li>
  );
}

// X-7
// X-4
export function Tenants() {
  const { t } = useI18n();
  return (
    <section className="stack">
      <h1>{t("nav.tenants")}</h1>
      <p className="muted">{t("operator.tenantsNote")}</p>
      <PagedTable<Tenant>
        title={t("nav.tenants")}
        path="/v1/operator/tenants"
        columns={[]}
        rowKey={(row) => row.id}
        after={(rows, reload) => (
          <ul className="plain stack">
            {rows.map((tenant) => (
              <TenantRow key={tenant.id} tenant={tenant} onDone={reload} />
            ))}
          </ul>
        )}
      />
    </section>
  );
}

function PlatformEngage({ onDone }: { onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const reasonId = useId();
  const ttlId = useId();
  const [reason, setReason] = useState("");
  const [ttl, setTtl] = useState("PT1H");
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    act(
      "/v1/operator/kill_switches",
      { target_kind: "all", state: "off", reason, ttl },
      key,
      () => {
        setKey(idempotencyKey());
        setReason("");
        onDone();
      },
      setError,
    );
  };
  return (
    <form className="row filters panel" onSubmit={submit}>
      <div className="field grow">
        <label htmlFor={reasonId}>{t("pii.reason")}</label>
        <input
          id={reasonId}
          required
          value={reason}
          onChange={(event) => {
            setReason(event.target.value);
          }}
        />
      </div>
      <div className="field">
        <label htmlFor={ttlId}>{t("killSwitch.ttl")}</label>
        <input
          id={ttlId}
          value={ttl}
          onChange={(event) => {
            setTtl(event.target.value.trim());
          }}
        />
      </div>
      <button type="submit" className="primary" disabled={reason.trim() === ""}>
        {t("operator.stopPlatform")}
      </button>
      {error && <span role="alert">{error}</span>}
    </form>
  );
}

// TN-41
export function PlatformKillSwitch() {
  const { t } = useI18n();
  const [round, setRound] = useState(0);
  const reload = () => {
    setRound((value) => value + 1);
  };
  const columns: Column<KillSwitch>[] = [
    {
      key: "state",
      header: t("status.label"),
      render: (row) => t(`killSwitch.state.${row.state}`),
    },
    {
      key: "target",
      header: t("killSwitch.target"),
      render: (row) => (
        <Mono>
          {row.channel ?? t("common.all")} · {row.target_kind}{" "}
          {row.target_ref ?? ""}
        </Mono>
      ),
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
      key: "actions",
      header: t("common.actions"),
      render: (row) =>
        row.status === "active" ? (
          <ReleaseButton
            path={`/v1/operator/kill_switches/${encodeURIComponent(row.id)}/release`}
            onDone={reload}
          />
        ) : (
          t("killSwitch.released")
        ),
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.platformKillSwitch")}</h1>
      <p className="muted">{t("killSwitch.stepUpNote")}</p>
      <PlatformEngage onDone={reload} />
      <PagedTable
        key={round}
        title={t("killSwitch.list")}
        path="/v1/operator/kill_switches"
        columns={columns}
        rowKey={(row) => row.id}
      />
    </section>
  );
}

// X-7
export function Regions() {
  const { t } = useI18n();
  const health = useGet<RegionHealth>("/v1/operator/region_health");
  return (
    <section className="stack">
      <h1>{t("nav.regions")}</h1>
      <Loadable state={health.state} onRetry={health.reload}>
        {(data) => (
          <div className="stack">
            <p>
              <span
                className={`badge tone-${data.status === "ok" ? "ok" : "warn"}`}
              >
                <span className="badge-label">
                  {data.region} · {t(`operator.region.${data.status}`)}
                </span>
              </span>{" "}
              <Time value={data.checked_at} />
            </p>
            <ul className="plain stack">
              {data.checks.map((check) => (
                <li key={check.name} className="row">
                  <strong>{check.name}</strong>
                  <span>{t(`operator.check.${check.status}`)}</span>
                  {check.reason && <code>{check.reason}</code>}
                </li>
              ))}
            </ul>
          </div>
        )}
      </Loadable>
      <Section title={t("nav.queues")}>
        <p>
          <a href="/v1/operator/queues">{t("operator.queuePanel")}</a>
        </p>
      </Section>
    </section>
  );
}
