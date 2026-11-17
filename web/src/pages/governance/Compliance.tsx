import { useGet } from "../../api/hooks";
import type { ServerSchemas } from "../../api/types";
import {
  DataTable,
  KeyValues,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";

type IysConfig = ServerSchemas["IysConfig"];
type IysUpload = ServerSchemas["IysUpload"];
type ComplianceSettings = ServerSchemas["ComplianceSettings"];
type Refusal = ServerSchemas["ComplianceRefusal"];
type Category = ServerSchemas["Category"];

function Iys() {
  const { t } = useI18n();
  const config = useGet<IysConfig>("/v1/iys/config");
  return (
    <Section title={t("compliance.iys")}>
      <Loadable state={config.state} onRetry={config.reload}>
        {(data) => (
          <div className="stack">
            {data.blocked_code && (
              <p className="notice" role="note">
                {t("compliance.blocked", { code: data.blocked_code })}
              </p>
            )}
            <KeyValues
              items={[
                [t("compliance.mode"), data.mode],
                [t("compliance.api"), data.api],
                [t("compliance.iysCode"), <Mono key="c">{data.iys_code}</Mono>],
                [t("compliance.quota"), t(`compliance.quotaState.${data.quota.state}`)],
                [
                  t("compliance.quotaUse"),
                  data.quota.consent_limit === null
                    ? "—"
                    : `${String(data.quota.used_consent_limit ?? 0)} / ${String(data.quota.consent_limit)}`,
                ],
                [t("compliance.checked"), <Time key="q" value={data.quota.checked_at} />],
                [t("compliance.brands"), data.brands.length],
              ]}
            />
          </div>
        )}
      </Loadable>
    </Section>
  );
}

function Refusals() {
  const { t } = useI18n();
  const settings = useGet<ComplianceSettings>("/v1/compliance_settings");
  const columns: Column<Refusal>[] = [
    { key: "country", header: t("reports.country"), render: (row) => row.country },
    {
      key: "kinds",
      header: t("compliance.refusedKinds"),
      render: (row) => row.consent_kinds.join(", "),
    },
  ];
  return (
    <Section title={t("compliance.countryRules")}>
      <Loadable state={settings.state} onRetry={settings.reload}>
        {(data) => (
          <div className="stack">
            <h3>{t("compliance.tenantRefusals")}</h3>
            <DataTable
              caption={t("compliance.tenantRefusals")}
              columns={columns}
              rows={data.refusals}
              rowKey={(row) => row.country}
            />
            <h3>{t("compliance.installationRefusals")}</h3>
            <DataTable
              caption={t("compliance.installationRefusals")}
              columns={columns}
              rows={data.installation_refusals}
              rowKey={(row) => row.country}
            />
          </div>
        )}
      </Loadable>
    </Section>
  );
}

// X-6
export function Compliance() {
  const { t } = useI18n();
  const uploads: Column<IysUpload>[] = [
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    { key: "status", header: t("compliance.consentStatus"), render: (row) => row.status },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    { key: "attempts", header: t("history.attempts"), render: (row) => row.attempts },
    {
      key: "error",
      header: t("history.failure"),
      render: (row) => (row.error_code ? <Mono>{row.error_code}</Mono> : "—"),
    },
    {
      key: "deadline",
      header: t("compliance.deadline"),
      render: (row) => <Time value={row.deadline_at} />,
    },
  ];
  const categories: Column<Category>[] = [
    { key: "key", header: t("topics.key"), render: (row) => <Mono>{row.key}</Mono> },
    { key: "name", header: t("agents.name"), render: (row) => row.name },
    { key: "class", header: t("activity.class"), render: (row) => row.message_class },
    {
      key: "locked",
      header: t("compliance.locked"),
      render: (row) =>
        row.locked ? (
          <span className="badge tone-info">
            <span aria-hidden="true">🔒</span>
            <span className="badge-label">{t("compliance.lockedYes")}</span>
          </span>
        ) : (
          t("common.no")
        ),
    },
    {
      key: "enabled",
      header: t("compliance.enabled"),
      render: (row) => (row.enabled ? t("common.yes") : t("common.no")),
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.compliance")}</h1>
      <Iys />
      <PagedTable
        title={t("compliance.uploads")}
        path="/v1/iys/uploads"
        columns={uploads}
        rowKey={(row) => row.id}
      />
      <Refusals />
      <PagedTable
        title={t("compliance.categories")}
        path="/v1/categories"
        columns={categories}
        rowKey={(row) => row.id}
      />
    </section>
  );
}
