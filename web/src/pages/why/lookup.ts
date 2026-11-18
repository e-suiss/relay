export type Lookup =
  | { kind: "email"; value: string }
  | { kind: "phone"; value: string }
  | { kind: "id"; value: string };

const email = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const phone = /^\+?[0-9][0-9 ().-]{5,}$/;

// X-12
/** Reads what the support person typed: an email address, a phone number (separators dropped) or a recipient identifier. */
export function parseLookup(input: string): Lookup | null {
  const value = input.trim();
  if (value === "") return null;
  if (email.test(value)) return { kind: "email", value: value.toLowerCase() };
  if (phone.test(value)) {
    const digits = value.replace(/[^0-9]/g, "");
    return {
      kind: "phone",
      value: value.startsWith("+") ? `+${digits}` : digits,
    };
  }
  return { kind: "id", value };
}
