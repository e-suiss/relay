import type {
  Channel,
  DeliveryStatus,
  DecisionStep,
  ServerSchemas,
} from "./types";

/** Schemas the console reads before the generated contract types carry them; each mirrors its OpenAPI schema field by field. */
export type FieldError = ServerSchemas["FieldError"];
export type GateFinding = ServerSchemas["GateFinding"];

export interface WorkflowPublicationCheck {
  object: "workflow_publication_check";
  publishable: boolean;
  errors: FieldError[];
}

export interface TemplatePublicationCheck {
  object: "template_publication_check";
  publishable: boolean;
  checksum: string;
  findings: GateFinding[];
}

export interface RouteUsageWorkflow {
  key: string;
  state: "published" | "draft" | "pending";
  version: number | null;
  steps: string[];
}

export interface RouteUsage {
  object: "route_usage";
  route_key: string;
  workflows: RouteUsageWorkflow[];
  categories: string[];
}

export interface EscalationPolicyUsage {
  object: "escalation_policy_usage";
  policy_key: string;
  latest_version: number;
  versions: { version: number; open: number; stalled: number }[];
}

export type ChannelRender = ServerSchemas["ChannelRender"];

export type SeedName =
  | "seed_no_consent"
  | "seed_opted_out"
  | "seed_quiet_hours"
  | "seed_capped"
  | "seed_bounced"
  | "seed_no_device"
  | "seed_fallback_timezone";

export interface SeedRecipient {
  object: "seed_recipient";
  external_id: SeedName;
  email: string;
  phone: string;
  email_result: string;
  description: string;
  set_up: boolean;
}

export interface SeedReset {
  object: "seed_reset";
  status: "queued";
}

export interface TestRender {
  content_digest: string;
  digest_only: "security_subtype" | "retention_none" | null;
  locale: string | null;
  output: Record<string, unknown> | null;
  rendered_at: string;
}

export interface TestInboxDelivery {
  delivery_id: string;
  channel: Channel;
  status: DeliveryStatus;
  reason?: string | null;
  rule_id?: string | null;
  gates: "passed" | "stopped" | "deferred";
  deferred_until?: string | null;
  decisions: DecisionStep[];
  render: TestRender | null;
}

export interface TestInboxMessage {
  object: "test_inbox_message";
  notification_id: string;
  event_id?: string | null;
  recipient_id: string;
  workflow: { key: string; version: number };
  message_class?: string;
  state: "active" | "cancelled" | "expired";
  close_rule_id?: string | null;
  created_at: string;
  deliveries: TestInboxDelivery[];
}
