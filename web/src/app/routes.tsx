import type { ReactNode } from "react";
import type { MessageKey } from "../i18n/en";
import { RouteSlot } from "../pages/RouteSlot";
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

export const pages: readonly ConsoleRoute[] = [];

export const routes: readonly ConsoleRoute[] = [
  ...pages,
  ...navigation
    .filter((item) => item.external !== true)
    .flatMap((item) => area(item.to, item.label)),
];
