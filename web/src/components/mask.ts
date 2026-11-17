const star = "•";

function hide(text: string, keep: number): string {
  const chars = [...text];
  if (chars.length <= keep) return star.repeat(Math.max(chars.length, 1));
  return chars.slice(0, keep).join("") + star.repeat(chars.length - keep);
}

// X-5
/** Masks an email address: the first letter of the local part and of the domain stay visible. */
export function maskEmail(value: string): string {
  const at = value.lastIndexOf("@");
  if (at <= 0) return hide(value, 1);
  const local = value.slice(0, at);
  const domain = value.slice(at + 1);
  const dot = domain.lastIndexOf(".");
  const host = dot > 0 ? domain.slice(0, dot) : domain;
  const tld = dot > 0 ? domain.slice(dot) : "";
  return `${hide(local, 1)}@${hide(host, 1)}${tld}`;
}

// X-5
/** Masks a phone number: the country prefix and the last two digits stay visible. */
export function maskPhone(value: string): string {
  const digits = [...value];
  if (digits.length <= 5) return star.repeat(digits.length);
  const head = value.startsWith("+") ? 3 : 1;
  return (
    digits.slice(0, head).join("") +
    star.repeat(digits.length - head - 2) +
    digits.slice(-2).join("")
  );
}

// X-5
/** Masks a personal name word by word, keeping each first letter. */
export function maskName(value: string): string {
  return value
    .split(/\s+/)
    .filter((word) => word !== "")
    .map((word) => hide(word, 1))
    .join(" ");
}

export function maskField(
  field: "email" | "phone" | "name",
  value: string | null | undefined,
): string | null {
  if (value === null || value === undefined || value === "") return null;
  if (value.includes(star)) return value;
  if (field === "email") return maskEmail(value);
  if (field === "phone") return maskPhone(value);
  return maskName(value);
}
