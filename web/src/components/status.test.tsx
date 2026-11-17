import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { Channel, DeliveryStatus } from "../api/types";
import { I18nProvider } from "../i18n/i18n";
import { en } from "../i18n/en";
import {
  ClickSplit,
  presentStatus,
  SenderTypeBadge,
  StatusBadge,
} from "./status";

const statuses: DeliveryStatus[] = [
  "queued",
  "sent",
  "delivered",
  "unknown_pending",
  "unknown",
  "failed",
  "skipped",
  "expired",
  "cancelled",
];

const channels: Channel[] = [
  "push",
  "web_push",
  "email",
  "sms",
  "voice",
  "whatsapp",
  "slack",
  "teams",
  "telegram",
  "discord",
  "in_app",
  "webhook",
];

describe("X-6 honest status display", () => {
  it("never labels a push delivery as delivered", () => {
    for (const channel of ["push", "web_push"] as const) {
      for (const status of statuses) {
        expect(presentStatus(status, channel).label).not.toBe(
          "status.delivered",
        );
      }
    }
  });

  it("shows unknown states as unknown, never as success", () => {
    for (const channel of channels) {
      for (const status of ["unknown_pending", "unknown"] as const) {
        const view = presentStatus(status, channel);
        expect(view.tone).not.toBe("ok");
        expect(en[view.label]).toMatch(/unknown/i);
      }
    }
  });

  it("gives every status a text label next to its colour", () => {
    render(
      <I18nProvider locale="en">
        {statuses.map((status) => (
          <StatusBadge key={status} status={status} channel="email" />
        ))}
      </I18nProvider>,
    );
    for (const status of statuses) {
      const label = en[presentStatus(status, "email").label];
      expect(screen.getByText(label)).toBeDefined();
    }
  });

  it("labels the sender type and splits human from bot clicks", () => {
    render(
      <I18nProvider locale="en">
        <SenderTypeBadge type="agent" />
        <ClickSplit human={4} bot={9} />
      </I18nProvider>,
    );
    expect(screen.getByText("Sent by an agent")).toBeDefined();
    expect(screen.getByText("Human: 4")).toBeDefined();
    expect(screen.getByText("Likely bot: 9")).toBeDefined();
  });
});
