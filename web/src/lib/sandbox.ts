// TP-39
/** The address a preview iframe may load: only an https link on an origin other than the console's own, so rendered HTML never shares the console's origin. */
export function sandboxSource(
  url: string | null | undefined,
  ownOrigin: string,
): string | null {
  if (url === null || url === undefined || url === "") return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:" || parsed.origin === ownOrigin) return null;
  return parsed.href;
}
