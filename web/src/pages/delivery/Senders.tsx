import { useState } from "react";
import { useGet } from "../../api/hooks";
import type { EmailDomainCheck, LooseRecord } from "../../api/pending";
import type { Page, ServerSchemas } from "../../api/types";
import {
  DataTable,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";

type SenderIdentity = ServerSchemas["SenderIdentity"];
type ChannelIdentity = ServerSchemas["ChannelIdentity"];
type ProviderAccount = ServerSchemas["ProviderAccount"];
type DnsRecord = EmailDomainCheck["records"][number];

// CH-36
function DomainWizard({ account }: { account: ProviderAccount }) {
  const { t } = useI18n();
  const checks = useGet<{ object: "list"; data: EmailDomainCheck[] }>(
    `/v1/provider_accounts/${encodeURIComponent(account.id)}/email_domains`,
  );
  const records: Column<DnsRecord>[] = [
    {
      key: "purpose",
      header: t("senders.purpose"),
      render: (row) => row.purpose,
    },
    { key: "type", header: t("senders.type"), render: (row) => row.type },
    {
      key: "name",
      header: t("senders.name"),
      render: (row) => <Mono>{row.name}</Mono>,
    },
    {
      key: "value",
      header: t("senders.value"),
      render: (row) => (row.value ? <Mono>{row.value}</Mono> : "—"),
    },
  ];
  return (
    <Loadable state={checks.state} onRetry={checks.reload}>
      {(data) => (
        <div className="stack">
          {data.data.map((check) => (
            <div
              key={check.stream}
              className="stack panel"
              data-domain={check.domain}
            >
              <div className="row">
                <strong>{check.domain}</strong>
                <span className="muted">{check.stream}</span>
                <span
                  className={`badge tone-${check.verified ? "ok" : "warn"}`}
                >
                  <span className="badge-label">
                    {check.verified
                      ? t("senders.verified")
                      : t("senders.notVerified")}
                  </span>
                </span>
                <span className="muted">
                  {t("senders.checked")} <Time value={check.checked_at} />
                </span>
              </div>
              <h3>{t("senders.records")}</h3>
              <DataTable
                caption={t("senders.records")}
                columns={records}
                rows={check.records}
                rowKey={(row) => `${row.purpose}/${row.name}`}
              />
              {check.findings.length > 0 && (
                <ul>
                  {check.findings.map((finding) => (
                    <li key={`${finding.code}/${finding.subject}`}>
                      <strong>
                        {t(`senders.severity.${finding.severity}`)}
                      </strong>{" "}
                      <code>{finding.code}</code> {finding.subject}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ))}
        </div>
      )}
    </Loadable>
  );
}

function EmailAccount({ account }: { account: ProviderAccount }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <li className="panel stack">
      <div className="row">
        <strong>{account.provider}</strong>
        <Mono>{account.id}</Mono>
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("senders.hideWizard") : t("senders.showWizard")}
        </button>
      </div>
      {open && <DomainWizard account={account} />}
    </li>
  );
}

function EmailDomains() {
  const { t } = useI18n();
  const accounts = useGet<Page<ProviderAccount>>("/v1/provider_accounts", {
    limit: 100,
  });
  return (
    <Section title={t("senders.domains")}>
      <Loadable state={accounts.state} onRetry={accounts.reload}>
        {(page) => {
          const email = page.data.filter(
            (account) => account.channel === "email",
          );
          if (email.length === 0)
            return <p className="muted">{t("common.empty")}</p>;
          return (
            <ul className="plain stack">
              {email.map((account) => (
                <EmailAccount key={account.id} account={account} />
              ))}
            </ul>
          );
        }}
      </Loadable>
    </Section>
  );
}

function summary(plan: LooseRecord): string {
  return Object.entries(plan)
    .filter(
      ([, value]) => typeof value === "string" || typeof value === "number",
    )
    .map(([key, value]) => `${key}: ${String(value)}`)
    .join(" · ");
}

// CH-36
function WarmUp() {
  const { t } = useI18n();
  const plans = useGet<{ data?: LooseRecord[] }>("/v1/email_warmup_plans");
  return (
    <Section title={t("senders.warmup")}>
      <Loadable state={plans.state} onRetry={plans.reload}>
        {(data) =>
          (data.data ?? []).length === 0 ? (
            <p className="muted">{t("common.empty")}</p>
          ) : (
            <ul>
              {(data.data ?? []).map((plan, index) => (
                <li key={index}>{summary(plan)}</li>
              ))}
            </ul>
          )
        }
      </Loadable>
    </Section>
  );
}

export function Senders() {
  const { t } = useI18n();
  const senders: Column<SenderIdentity>[] = [
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    { key: "kind", header: t("waitpoints.kind"), render: (row) => row.kind },
    {
      key: "value",
      header: t("senders.value"),
      render: (row) => <Mono>{row.value}</Mono>,
    },
    {
      key: "country",
      header: t("reports.country"),
      render: (row) => row.country ?? "—",
    },
    {
      key: "approval",
      header: t("senders.approval"),
      render: (row) => t(`senders.approvalState.${row.approval_state}`),
    },
    {
      key: "suspended",
      header: t("senders.suspended"),
      render: (row) =>
        row.suspended_at ? (
          <span>
            <Time value={row.suspended_at} />{" "}
            {row.suspension_rule_id && <Mono>{row.suspension_rule_id}</Mono>}
          </span>
        ) : (
          "—"
        ),
    },
  ];
  const identities: Column<ChannelIdentity>[] = [
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    { key: "kind", header: t("waitpoints.kind"), render: (row) => row.kind },
    {
      key: "app",
      header: t("why.app"),
      render: (row) => <Mono>{row.app_ref}</Mono>,
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.senders")}</h1>
      <PagedTable
        title={t("senders.identities")}
        path="/v1/sender_identities"
        columns={senders}
        rowKey={(row) => row.id}
      />
      <EmailDomains />
      <WarmUp />
      <PagedTable
        title={t("senders.channelIdentities")}
        path="/v1/channel_identities"
        columns={identities}
        rowKey={(row) => row.id}
      />
    </section>
  );
}
