import type { ServerSchemas } from "../../api/types";
import { Link } from "../../app/router";
import { Mono, Time, type Column } from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { useI18n } from "../../i18n/i18n";

type Template = ServerSchemas["Template"];
type Layout = ServerSchemas["Layout"];
type PartialBlock = ServerSchemas["Partial"];

function live(version: number | null | undefined): string {
  return version === null || version === undefined ? "—" : `v${version}`;
}

// TP-10
export function Templates() {
  const { t } = useI18n();
  const templates: Column<Template>[] = [
    {
      key: "key",
      header: t("tpl.key"),
      render: (row) => (
        <Link to={`/templates/${encodeURIComponent(row.key)}`}>
          <Mono>{row.key}</Mono>
        </Link>
      ),
    },
    { key: "name", header: t("wf.name"), render: (row) => row.name },
    {
      key: "type",
      header: t("tpl.type"),
      render: (row) => t(`tpl.type.${row.type}`),
    },
    {
      key: "owner",
      header: t("tpl.owner"),
      render: (row) =>
        row.protected
          ? `${t(`tpl.owner.${row.owner}`)} · ${t("tpl.protected")}`
          : t(`tpl.owner.${row.owner}`),
    },
    { key: "live", header: t("wf.live"), render: (row) => live(row.live_version) },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  const layouts: Column<Layout>[] = [
    { key: "key", header: t("tpl.key"), render: (row) => <Mono>{row.key}</Mono> },
    { key: "name", header: t("wf.name"), render: (row) => row.name },
    { key: "live", header: t("wf.live"), render: (row) => live(row.live_version) },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  const partials: Column<PartialBlock>[] = [
    { key: "key", header: t("tpl.key"), render: (row) => <Mono>{row.key}</Mono> },
    { key: "name", header: t("wf.name"), render: (row) => row.name },
    {
      key: "locales",
      header: t("tpl.locales"),
      render: (row) => Object.keys(row.draft?.bodies ?? {}).join(", ") || "—",
    },
    { key: "live", header: t("wf.live"), render: (row) => live(row.live_version) },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.templates")}</h1>
      <p className="muted">{t("tpl.intro")}</p>
      <PagedTable
        title={t("tpl.templates")}
        path="/v1/templates"
        columns={templates}
        rowKey={(row) => row.id}
      />
      <PagedTable
        title={t("tpl.layouts")}
        path="/v1/layouts"
        columns={layouts}
        rowKey={(row) => row.id}
      />
      <PagedTable
        title={t("tpl.partials")}
        path="/v1/partials"
        columns={partials}
        rowKey={(row) => row.id}
      />
    </section>
  );
}
