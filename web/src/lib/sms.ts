export type SmsEncoding = "GSM7" | "GSM7_TR" | "UCS2";

const basic = Array.from(
  "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà",
);
const extension = Array.from("^{}\\[~]|€");
const turkish = Array.from("ĞİŞçğış");

const gsm7 = new Map<string, number>([
  ...basic.map((char): [string, number] => [char, 1]),
  ...extension.map((char): [string, number] => [char, 2]),
]);
const gsm7Tr = new Map<string, number>([
  ...gsm7,
  ...["Ç", ...turkish].map((char): [string, number] => [char, 2]),
]);

const limits: Record<SmsEncoding, readonly [number, number]> = {
  GSM7: [160, 152],
  GSM7_TR: [155, 148],
  UCS2: [70, 66],
};

const letters: Record<string, string> = { ı: "i" };

function cost(char: string, encoding: SmsEncoding): number | undefined {
  if (encoding === "GSM7") return gsm7.get(char);
  if (encoding === "GSM7_TR") return gsm7Tr.get(char);
  return (char.codePointAt(0) ?? 0) > 0xffff ? 2 : 1;
}

/** The unit cost of every code point of the text in an encoding, or null when the encoding cannot carry one of them. */
export function units(text: string, encoding: SmsEncoding): number[] | null {
  const result: number[] = [];
  for (const char of Array.from(text)) {
    const unit = cost(char, encoding);
    if (unit === undefined) return null;
    result.push(unit);
  }
  return result;
}

// TP-18
/** The cheapest encoding for the text under the default Turkish single shift policy. */
export function chooseEncoding(text: string): SmsEncoding {
  if (units(text, "GSM7") !== null) return "GSM7";
  if (units(text, "GSM7_TR") !== null) return "GSM7_TR";
  return "UCS2";
}

// TP-18
/** Splits the text into the segments it takes in an encoding, never splitting an escaped character or a surrogate pair. */
export function segments(text: string, encoding: SmsEncoding): string[] {
  const chars = Array.from(text);
  const costs = units(text, encoding) ?? chars.map(() => 1);
  if (chars.length === 0) return [];
  const [single, perSegment] = limits[encoding];
  const total = costs.reduce((sum, unit) => sum + unit, 0);
  if (total <= single) return [text];
  const parts: string[] = [];
  let current = "";
  let used = 0;
  chars.forEach((char, index) => {
    const unit = costs[index] ?? 1;
    if (used + unit > perSegment) {
      parts.push(current);
      current = "";
      used = 0;
    }
    current += char;
    used += unit;
  });
  parts.push(current);
  return parts;
}

export interface SmsMeasure {
  encoding: SmsEncoding;
  segments: string[];
  characters: number;
}

/** The planned encoding, segments and characters of a text. */
export function measureSms(text: string): SmsMeasure {
  const encoding = chooseEncoding(text);
  return {
    encoding,
    segments: segments(text, encoding),
    characters: Array.from(text).length,
  };
}

function base(char: string): string | null {
  if (gsm7.has(char)) return null;
  const letter = letters[char];
  if (letter !== undefined) return letter;
  const stripped = char.normalize("NFD").replace(/[̀-ͯ]/g, "");
  if (stripped === "" || stripped === char) return null;
  return units(stripped, "GSM7") === null ? null : stripped;
}

// CH-49
/** Replaces letters the GSM default alphabet cannot carry with their base letters, as the server's transliteration does. */
export function transliterate(text: string): string {
  return Array.from(text)
    .map((char) => base(char) ?? char)
    .join("");
}
