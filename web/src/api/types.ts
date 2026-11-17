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
