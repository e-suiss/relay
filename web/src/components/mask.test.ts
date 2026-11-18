import { describe, expect, it } from "vitest";
import { maskEmail, maskField, maskName, maskPhone } from "./mask";

describe("X-5 masked personal data", () => {
  it("never shows a whole email address, phone number or name", () => {
    expect(maskEmail("ayse.yilmaz@example.com")).toBe(
      "a••••••••••@e••••••.com",
    );
    expect(maskPhone("+905321234567")).toBe("+90••••••••67");
    expect(maskName("Ayşe Yılmaz")).toBe("A••• Y•••••");
  });

  it("leaves an already masked value as it is", () => {
    expect(maskField("email", "a•••@e•••.com")).toBe("a•••@e•••.com");
    expect(maskField("phone", null)).toBeNull();
  });
});
