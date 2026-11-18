/** The URL when it is safe to put in a link: http, https or a relative address; null otherwise. */
export function safeUrl(url: unknown): string | null {
  if (typeof url !== "string" || url.length === 0) return null;
  try {
    const parsed = new URL(url, "https://relative.invalid");
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? url : null;
  } catch {
    return null;
  }
}

/** Whether a URL is on an origin. */
export function onOrigin(url: string, origin: string): boolean {
  try {
    return new URL(url).origin === new URL(origin).origin;
  } catch {
    return false;
  }
}
