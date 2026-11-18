import { describe, expect, it } from "vitest";
import { href, match, stripBase } from "./router";

describe("X-47 console routing", () => {
  it("serves every page under /console", () => {
    expect(stripBase("/console")).toBe("/");
    expect(stripBase("/console/")).toBe("/");
    expect(stripBase("/console/why/")).toBe("/why");
    expect(href("/workflows/welcome")).toBe("/console/workflows/welcome");
  });

  it("matches parameters and rest segments", () => {
    expect(match("/workflows/:key", "/workflows/welcome")).toEqual({
      key: "welcome",
    });
    expect(match("/workflows", "/workflows/welcome")).toBeNull();
    expect(match("/templates/*", "/templates/a/b")).toEqual({ "*": "a/b" });
  });
});
