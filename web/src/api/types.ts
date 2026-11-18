import type { components as ServerComponents } from "./generated/server";
import type { components as OperatorComponents } from "./generated/operator";

export type ServerSchemas = ServerComponents["schemas"];
export type OperatorSchemas = OperatorComponents["schemas"];

export type OperatorSession = OperatorSchemas["OperatorSession"];
export type RoleGrant = OperatorSchemas["RoleGrant"];
export type StepUpChallenge = OperatorSchemas["StepUpChallenge"];
export type RevealResult = OperatorSchemas["RevealResult"];
export type RevealField = OperatorSchemas["RevealRequest"]["fields"][number];

export type Environment = "live" | "test";
export type Channel = ServerSchemas["Delivery"]["channel"];
export type DeliveryStatus = ServerSchemas["Delivery"]["status"];
export type SenderType = ServerSchemas["Notification"]["sender_type"];

export type Notification = ServerSchemas["Notification"];
export type Delivery = ServerSchemas["Delivery"];
export type DeliveryHistory = ServerSchemas["DeliveryHistory"];
export type Attempt = ServerSchemas["Attempt"];
export type LedgerEvent = ServerSchemas["LedgerEvent"];
export type Subscriber = ServerSchemas["Subscriber"];
export type NotificationDecision = ServerSchemas["NotificationDecision"];
export type DeliveryDecision = ServerSchemas["DeliveryDecision"];
export type DecisionStep = ServerSchemas["DecisionStep"];
export type Consent = ServerSchemas["Consent"];
export type Device = ServerSchemas["Device"];
export type SubscriberPreferences = ServerSchemas["SubscriberPreferences"];
export type TopicSubscription = ServerSchemas["TopicSubscription"];
export type Topic = ServerSchemas["Topic"];

export type BreakerState = ServerSchemas["BreakerState"];
export type ProviderAccountStatus = ServerSchemas["ProviderAccountStatus"];
export type EmailDomainCheck = ServerSchemas["EmailDomainCheck"];
export type EmailDomainCheckList = ServerSchemas["EmailDomainCheckList"];
export type EmailWarmupPlanList = ServerSchemas["EmailWarmupPlanList"];
export type ChannelCostQuote = ServerSchemas["ChannelCostQuote"];
export type RegionHealth = OperatorSchemas["RegionHealth"];

export interface Problem {
  type?: string;
  title?: string;
  status?: number;
  detail?: string;
  code?: string;
  retryable?: boolean;
}

export interface Page<T> {
  object: "list";
  data: T[];
  has_more: boolean;
  next_cursor?: string | null;
  previous_cursor?: string | null;
}
