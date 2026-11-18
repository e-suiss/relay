export type BreakerState = "closed" | "open" | "half_open";

export interface ProviderAccountStatus {
  object: "provider_account_status";
  provider_account_id: string;
  channel: string;
  provider: string;
  data_residency: {
    sends_data_abroad: boolean;
    reference_region: "tr" | "eu" | "us";
    abroad_countries: string[];
    in_installation: boolean;
    transfer_basis: string | null;
  };
  adapter: {
    declared: boolean;
    adapter_version: string | null;
    activated: boolean;
    deprecation_warning: boolean;
    deprecations: { api: string; sunset_on: string | null }[];
  };
  circuit_breaker: {
    provider: BreakerState;
    account: BreakerState;
    observed_by: "node";
  };
}

export interface EmailDomainCheck {
  object: "email_domain_check";
  stream: "transactional" | "marketing";
  domain: string;
  verified: boolean;
  checked_at: string;
  records: {
    purpose: "return_path" | "dkim" | "spf" | "dmarc";
    type: "CNAME" | "TXT";
    name: string;
    value: string | null;
  }[];
  findings: {
    severity: "error" | "warning" | "suggestion";
    code: string;
    subject: string;
  }[];
}

export interface CostQuoteRow {
  provider_account_id: string;
  provider: string;
  routable: boolean;
  paid: boolean;
  priced: boolean;
  source: "provider_declaration" | "whatsapp_rate_card";
  currency: string | null;
  unit: string | null;
  unit_price_micros: number | null;
  total_micros: number | null;
  tier_from: number | null;
}

export interface ChannelCostQuote {
  object: "channel_cost_quote";
  channel: "sms" | "voice" | "whatsapp";
  country: string;
  category: string | null;
  quantity: number;
  data: CostQuoteRow[];
}

export interface RegionHealth {
  object: "region_health";
  region: "tr" | "eu" | "us";
  status: "ok" | "degraded";
  checked_at: string;
  checks: {
    name: string;
    status: "ok" | "unavailable";
    reason: string | null;
  }[];
  queue_panel_url: string;
}

export type LooseRecord = Record<string, unknown>;
