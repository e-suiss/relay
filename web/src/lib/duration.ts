const pattern = /^P(?!$)(\d+W)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$/;

function amount(part: string | undefined): number {
  return part === undefined ? 0 : Number.parseInt(part, 10);
}

/** True for an ISO 8601 duration of weeks, days, hours, minutes and seconds. */
export function isDuration(value: string): boolean {
  return pattern.test(value);
}

/** The seconds of an ISO 8601 duration, or null when it is not one. */
export function durationSeconds(value: string): number | null {
  const parts = pattern.exec(value);
  if (parts === null) return null;
  return (
    amount(parts[1]) * 604_800 +
    amount(parts[2]) * 86_400 +
    amount(parts[4]) * 3_600 +
    amount(parts[5]) * 60 +
    amount(parts[6])
  );
}

const units = [
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
  ["second", 1],
] as const;

/** A short human reading of a number of seconds in the console language, such as "1d 2h" or "1 g 2 sa". */
export function humanDuration(seconds: number, locale: string): string {
  if (seconds <= 0)
    return new Intl.NumberFormat(locale, unit("second")).format(0);
  const parts: string[] = [];
  let rest = seconds;
  for (const [name, size] of units) {
    const count = Math.floor(rest / size);
    if (count > 0) {
      parts.push(new Intl.NumberFormat(locale, unit(name)).format(count));
      rest -= count * size;
    }
  }
  return parts.join(" ");
}

function unit(name: string): Intl.NumberFormatOptions {
  return { style: "unit", unit: name, unitDisplay: "narrow" };
}
