import { useGet } from "../../api/hooks";
import type { OperatorSchemas, Page } from "../../api/types";
import {
  DataTable,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { useI18n } from "../../i18n/i18n";

type ApiClient = OperatorSchemas["ApiClient"];
type RoleAssignment = OperatorSchemas["RoleAssignment"];
type Role = OperatorSchemas["Role"];

function Roles() {
  const { t } = useI18n();
  const roles = useGet<Page<Role>>("/v1/operator/roles");
  const columns: Column<Role>[] = [
    { key: "key", header: t("settings.role"), render: (row) => <Mono>{row.key}</Mono> },
    { key: "scope", header: t("killSwitch.scope"), render: (row) => row.scope },
    { key: "description", header: t("settings.description"), render: (row) => row.description },
  ];
  return (
    <Section title={t("settings.roles")}>
      <Loadable state={roles.state} onRetry={roles.reload}>
        {(page) => (
          <DataTable
            caption={t("settings.roles")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.key}
          />
        )}
      </Loadable>
    </Section>
  );
}

// X-2
export function Settings() {
  const { t } = useI18n();
  const clients: Column<ApiClient>[] = [
    {
      key: "client",
      header: t("settings.accessClient"),
      render: (row) => <Mono>{row.access_client_id}</Mono>,
    },
    { key: "env", header: t("context.environment"), render: (row) => t(`env.${row.environment}`) },
    { key: "scopes", header: t("settings.scopes"), render: (row) => row.scopes.join(", ") },
    { key: "status", header: t("activity.state"), render: (row) => row.status },
    {
      key: "used",
      header: t("settings.lastUsed"),
      render: (row) => (
        <span>
          <Time value={row.last_used_at} />
          {row.unused_warning && (
            <span className="badge tone-warn">
              <span className="badge-label">{t("settings.unused")}</span>
            </span>
          )}
        </span>
      ),
    },
  ];
  const assignments: Column<RoleAssignment>[] = [
    {
      key: "operator",
      header: t("settings.operator"),
      render: (row) => <Mono>{row.operator_id}</Mono>,
    },
    { key: "role", header: t("settings.role"), render: (row) => <Mono>{row.role}</Mono> },
    {
      key: "env",
      header: t("context.environment"),
      render: (row) => (row.environment ? t(`env.${row.environment}`) : "—"),
    },
    { key: "status", header: t("activity.state"), render: (row) => row.status },
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => <Time value={row.created_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.settings")}</h1>
      <PagedTable
        title={t("settings.apiClients")}
        path="/v1/operator/api_clients"
        columns={clients}
        rowKey={(row) => row.id}
      />
      <p className="muted">{t("settings.apiClientsNote")}</p>
      <Roles />
      <PagedTable
        title={t("settings.assignments")}
        path="/v1/operator/role_assignments"
        columns={assignments}
        rowKey={(row) => row.id}
      />
      <Section title={t("settings.defaults")}>
        <p className="muted">{t("settings.defaultsNote")}</p>
      </Section>
    </section>
  );
}
