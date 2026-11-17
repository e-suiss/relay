/** One Server-Sent Event. */
export interface SseEvent {
  readonly event: string;
  readonly data: string;
  /** The last event id seen on the stream, including this event's own. */
  readonly id: string | null;
}

/** Parses a text/event-stream body into events (WHATWG HTML server-sent events). */
export async function* readSse(stream: ReadableStream<Uint8Array>): AsyncGenerator<SseEvent, void, undefined> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let event = "";
  let data: string[] = [];
  let lastId: string | null = null;

  const line = (text: string): SseEvent | null => {
    if (text === "") {
      const dispatched =
        data.length === 0 ? null : { event: event === "" ? "message" : event, data: data.join("\n"), id: lastId };
      event = "";
      data = [];
      return dispatched;
    }
    if (text.startsWith(":")) return null;
    const colon = text.indexOf(":");
    const field = colon === -1 ? text : text.slice(0, colon);
    let value = colon === -1 ? "" : text.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    else if (field === "data") data.push(value);
    else if (field === "id" && !value.includes("\u0000")) lastId = value;
    return null;
  };

  try {
    for (;;) {
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      let match: RegExpExecArray | null;
      while ((match = /\r\n|\r|\n/.exec(buffer)) !== null) {
        if (match[0] === "\r" && match.index === buffer.length - 1 && !done) break;
        const text = buffer.slice(0, match.index);
        buffer = buffer.slice(match.index + match[0].length);
        const dispatched = line(text);
        if (dispatched !== null) yield dispatched;
      }
      if (done) return;
    }
  } finally {
    reader.releaseLock();
  }
}
