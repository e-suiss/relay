import type { ReactNode } from "react";
import type { MessageKey } from "../i18n/en";
import { Activity } from "../pages/activity/Activity";
import { AgentCeiling, Agents, Topics } from "../pages/agents/Agents";
import { Waitpoints } from "../pages/agents/Waitpoints";
import { Audit } from "../pages/governance/Audit";
import { KillSwitches } from "../pages/governance/KillSwitches";
import { NotificationDetail } from "../pages/activity/NotificationDetail";
import { RecipientDetail, Recipients } from "../pages/recipients/Recipients";
import { Reports } from "../pages/reports/Reports";
import { RouteSlot } from "../pages/RouteSlot";
import { Why } from "../pages/why/Why";
import type { Params } from "./router";

export type NavGroup =
  | "nav.group.activity"
  | "nav.group.build"
  | "nav.group.audience"
  | "nav.group.delivery"
  | "nav.group.governance"
  | "nav.group.operator";

export interface NavItem {
  to: string;
  label: MessageKey;
  group: NavGroup;
  operator?: boolean;
  external?: boolean;
}

export interface ConsoleRoute {
  pattern: string;
  render: (params: Params) => ReactNode;
}

export const navigation: readonly NavItem[] = [
  { to: "/activity", label: "nav.activity", group: "nav.group.activity" },
  { to: "/why", label: "nav.why", group: "nav.group.activity" },
  { to: "/reports", label: "nav.reports", group: "nav.group.activity" },
  { to: "/test-inbox", label: "nav.testInbox", group: "nav.group.activity" },
  { to: "/workflows", label: "nav.workflows", group: "nav.group.build" },
  { to: "/templates", label: "nav.templates", group: "nav.group.build" },
  { to: "/escalation", label: "nav.escalation", group: "nav.group.build" },
  { to: "/recipients", label: "nav.recipients", group: "nav.group.audience" },
  { to: "/topics", label: "nav.topics", group: "nav.group.audience" },
  { to: "/agents", label: "nav.agents", group: "nav.group.audience" },
  { to: "/waitpoints", label: "nav.waitpoints", group: "nav.group.audience" },
  { to: "/agent-ceiling", label: "nav.ceiling", group: "nav.group.audience" },
  { to: "/channels", label: "nav.channels", group: "nav.group.delivery" },
  { to: "/senders", label: "nav.senders", group: "nav.group.delivery" },
  { to: "/webhooks", label: "nav.webhooks", group: "nav.group.delivery" },
  { to: "/compliance", label: "nav.compliance", group: "nav.group.governance" },
  {
    to: "/kill-switches",
    label: "nav.killSwitches",
    group: "nav.group.governance",
  },
  { to: "/audit", label: "nav.audit", group: "nav.group.governance" },
  { to: "/settings", label: "nav.settings", group: "nav.group.governance" },
  {
    to: "/operator/tenants",
    label: "nav.tenants",
    group: "nav.group.operator",
    operator: true,
  },
  {
    to: "/operator/kill-switch",
    label: "nav.platformKillSwitch",
    group: "nav.group.operator",
    operator: true,
  },
  {
    to: "/operator/regions",
    label: "nav.regions",
    group: "nav.group.operator",
    operator: true,
  },
  {
    to: "/v1/operator/queues",
    label: "nav.queues",
    group: "nav.group.operator",
    operator: true,
    external: true,
  },
];

function slot(area: MessageKey): ConsoleRoute["render"] {
  return () => <RouteSlot area={area} />;
}

function area(path: string, label: MessageKey): ConsoleRoute[] {
  return [
    { pattern: path, render: slot(label) },
    { pattern: `${path}/*`, render: slot(label) },
  ];
}

function param(params: Params, name: string): string {
  return params[name] ?? "";
}

export const pages: readonly ConsoleRoute[] = [
  { pattern: "/activity", render: () => <Activity /> },
  {
    pattern: "/activity/notifications/:id",
    render: (params) => {
      const id = param(params, "id");
      return <NotificationDetail key={id} id={id} />;
    },
  },
  { pattern: "/why", render: () => <Why /> },
  { pattern: "/recipients", render: () => <Recipients /> },
  { pattern: "/reports", render: () => <Reports /> },
  { pattern: "/audit", render: () => <Audit /> },
  { pattern: "/kill-switches", render: () => <KillSwitches /> },
  { pattern: "/waitpoints", render: () => <Waitpoints /> },
  { pattern: "/agent-ceiling", render: () => <AgentCeiling /> },
  { pattern: "/agents", render: () => <Agents /> },
  { pattern: "/topics", render: () => <Topics /> },
  {
    pattern: "/recipients/:id",
    render: (params) => {
      const id = param(params, "id");
      return <RecipientDetail key={id} id={id} />;
    },
  },
];

export const routes: readonly ConsoleRoute[] = [
  ...pages,
  ...navigation
    .filter((item) => item.external !== true)
    .flatMap((item) => area(item.to, item.label)),
];
