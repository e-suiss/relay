import { describe, expect, it } from "vitest";
import type { RoleGrant } from "../api/types";
import { resolveContext, tenantChoices } from "./session";

const a = "ten_01hzx3k5v7m9p2q4r6s8t0w2y4";
const b = "ten_01hzx3k5v7m9p2q4r6s8t0w2y5";
const stn = "stn_01hzx3k5v7m9p2q4r6s8t0w2y4";

const roles: RoleGrant[] = [
  { role: "tenant_operator", tenant_id: b, environment: "live" },
  { role: "tenant_admin", tenant_id: a, environment: "test" },
  { role: "tenant_operator", tenant_id: a, environment: "live" },
  { role: "installation_operator", tenant_id: null, environment: null },
];

describe("X-4 one tenant context", () => {
  it("offers the tenants and environments of the session's roles", () => {
    expect(tenantChoices(roles)).toEqual([
      { tenant: a, environments: ["live", "test"] },
      { tenant: b, environments: ["live"] },
    ]);
  });

  it("always resolves to one tenant and an environment the role allows", () => {
    const choices = tenantChoices(roles);
    expect(resolveContext({}, choices)).toEqual({
      tenant: a,
      environment: "live",
      subtenant: null,
    });
    expect(resolveContext({ tenant: b, environment: "test" }, choices)).toEqual(
      { tenant: b, environment: "live", subtenant: null },
    );
    expect(
      resolveContext(
        { tenant: a, environment: "test", subtenant: stn },
        choices,
      ),
    ).toEqual({ tenant: a, environment: "test", subtenant: stn });
    expect(resolveContext({ subtenant: "nope" }, choices).subtenant).toBeNull();
  });
});
