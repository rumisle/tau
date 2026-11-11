// Provider errors as people read them (iOS's ModelErrorText): they come as the provider's text, often an HTTP status
// and a JSON body (`529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`).

/** The message itself: a JSON body's innermost `message`, with its status before it */
export function cleanModelError(raw: string) {
  const text = raw.trim();
  const brace = text.indexOf('{');
  if (brace < 0) return text;
  let json: unknown;
  try {
    json = JSON.parse(text.slice(brace));
  } catch {
    return text;
  }
  const message = (value: unknown): string | undefined => {
    if (value && typeof value === 'object') {
      const object = value as Record<string, unknown>;
      const inner = object.error !== undefined ? message(object.error) : undefined;
      if (inner) return inner;
      if (typeof object.message === 'string' && object.message) return object.message;
    }
    return typeof value === 'string' && value ? value : undefined;
  };
  const found = message(json);
  if (!found) return text;
  const prefix = text.slice(0, brace).trim();
  return prefix ? `${prefix}: ${found}` : found;
}

const KINDS: [RegExp, string][] = [
  [/overloaded|at capacity|high demand|server_busy|servers are currently busy/, 'overloaded'],
  [/rate.?limit|too many requests|\b429\b|resourceexhausted/, 'rate limited'],
  [/timed? ?out|timeout/, 'timed out'],
  [new RegExp(['network', 'connection', 'socket', 'fetch failed', 'econn', 'enotfound', 'eai_again', 'getaddrinfo',
    'other side closed', 'websocket', 'terminated', 'stream (was interrupted|ended)', 'ended without'].join('|')),
  'connection lost'],
  [/\b5\d\d\b|server.?error|internal.?error|unavailable|upstream|provider returned/, 'server error'],
];

/** A few words for a status line: what kind of error, or the start of the message */
export function modelErrorReason(raw: string) {
  const lowered = raw.toLowerCase();
  const kind = KINDS.find(([pattern]) => pattern.test(lowered));
  if (kind) return kind[1];
  const cleaned = cleanModelError(raw);
  return cleaned.length > 40 ? `${cleaned.slice(0, 39)}…` : cleaned;
}
