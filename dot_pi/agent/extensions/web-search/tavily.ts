// Public protocol: https://docs.tavily.com/documentation/keyless
// Deliberately never reads credentials, retries, or falls back to paid access.
export interface SearchParams {
  query: string;
  max_results?: number;
}

export interface SearchResult {
  title: string;
  url: string;
  content: string;
}

export interface SearchResponse {
  query: string;
  results: SearchResult[];
  truncated?: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function limitMessage(retryAfter: unknown): string {
  const seconds = typeof retryAfter === "number" || typeof retryAfter === "string" ? Number(retryAfter) : NaN;
  const wait = Number.isFinite(seconds) && seconds > 0 ? ` Wait at least ${Math.ceil(seconds)} seconds.` : " Try later.";
  return `Tavily keyless rate/quota limit reached.${wait} No paid fallback is configured; do not retry immediately.`;
}

async function readJson(response: Response, signal: AbortSignal): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Unexpected empty Tavily response.");
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  try {
    while (true) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 1_048_576) {
        await reader.cancel();
        throw new Error("Tavily response is too large (over 1 MiB).");
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
  } finally {
    reader.releaseLock();
  }
  signal.throwIfAborted();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error("Invalid JSON in Tavily search response.");
  }
}

function parseResult(value: unknown): SearchResult {
  if (!isRecord(value) || typeof value.title !== "string" || typeof value.url !== "string"
      || typeof value.content !== "string" || value.url.length > 2048) {
    throw new Error("Unexpected Tavily search result format.");
  }
  let url: URL;
  try {
    url = new URL(value.url);
  } catch {
    throw new Error("Invalid URL in Tavily search result.");
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || url.href.length > 2048) {
    throw new Error("Invalid URL protocol or length in Tavily search result.");
  }
  return {
    title: value.title.length > 200 ? value.title.slice(0, 200) + "…" : value.title,
    url: url.href,
    content: value.content.length > 1000 ? value.content.slice(0, 1000) + "… [truncated]" : value.content,
  };
}

export async function webSearch(params: SearchParams, signal?: AbortSignal): Promise<SearchResponse> {
  const query = typeof params.query === "string" ? params.query.trim() : "";
  const maxResults = params.max_results ?? 5;
  if (!query || query.length > 500) throw new Error("query must contain 1–500 non-blank characters.");
  if (!Number.isInteger(maxResults) || maxResults < 1 || maxResults > 5) {
    throw new Error("max_results must be an integer from 1 to 5.");
  }
  signal?.throwIfAborted();
  const timeout = AbortSignal.timeout(20_000);
  const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
  const response = await fetch("https://api.tavily.com/search", {
    method: "POST",
    redirect: "error",
    signal: requestSignal,
    headers: { "Content-Type": "application/json", "X-Tavily-Access-Mode": "keyless" },
    body: JSON.stringify({
      query, max_results: maxResults, search_depth: "basic", auto_parameters: false,
      include_answer: false, include_raw_content: false,
    }),
  });
  requestSignal.throwIfAborted();
  if (!response.ok) {
    await response.body?.cancel();
    if (response.status === 402 || response.status === 429 || response.status === 432 || response.status === 433) {
      throw new Error(limitMessage(response.headers.get("Retry-After")));
    }
    throw new Error(`Tavily keyless search failed (HTTP ${response.status}). No paid fallback was used.`);
  }
  const body = await readJson(response, requestSignal);
  if (isRecord(body) && body.error != null) {
    if (isRecord(body.error) && typeof body.error.code === "string" && /limit|quota|budget|cap/i.test(body.error.code)) {
      throw new Error(limitMessage(body.error.retry_after_seconds));
    }
    throw new Error("Unexpected Tavily error response. No paid fallback was used.");
  }
  if (!isRecord(body) || !Array.isArray(body.results)) throw new Error("Unexpected Tavily search response format.");
  const result: SearchResponse = { query, results: body.results.slice(0, maxResults).map(parseResult) };
  // JSON escaping can expand even canonical URLs. Bound the actual model-facing
  // representation, not an estimate derived from string lengths.
  const encoder = new TextEncoder();
  while (encoder.encode(JSON.stringify(result, null, 2)).byteLength > 48_000 && result.results.length) {
    result.results.pop();
    result.truncated = true;
  }
  return result;
}
