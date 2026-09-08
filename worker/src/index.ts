export interface Env {
  DB: D1Database;
}

interface MachineAuth {
  machine: string;
  readPrefixes: string[];
  writePrefixes: string[];
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const MAX_STATE_BYTES = 256 * 1024;
// Archive envelopes add retention metadata around otherwise valid active records and
// compact several significant events. Keep active writes at the original bound while
// allowing bounded GC output without granting broader scopes or bypassing auth.
const MAX_ARCHIVE_STATE_BYTES = 1024 * 1024;
const REQUEST_ENVELOPE_BYTES = 4096;
const MAX_ACTIVE_STATE_PATH_BYTES = 512;
const MAX_ARCHIVE_STATE_PATH_BYTES = MAX_ACTIVE_STATE_PATH_BYTES + "archive/".length;
const MAX_LIST_LIMIT = 1000;
const ARCHIVABLE_RECORD_PATH = "(?:claims/[A-Za-z0-9_.:-]+/[A-Za-z0-9_.:-]+/[A-Za-z0-9_.:-]+\\.json"
  + "|heartbeats/[A-Za-z0-9_.:-]+\\.json"
  + "|batches/[A-Za-z0-9_.:-]+\\.json"
  + "|events/[A-Za-z0-9_.:-]+/[A-Za-z0-9_.:-]+\\.json)";
const STATE_PATH = new RegExp(`^(?:${ARCHIVABLE_RECORD_PATH}|archive/${ARCHIVABLE_RECORD_PATH})$`);
const ARCHIVABLE_PREFIX = "(?:claims(?:/[A-Za-z0-9_.:-]+(?:/[A-Za-z0-9_.:-]+)?)?"
  + "|heartbeats|batches|events(?:/[A-Za-z0-9_.:-]+)?)";
const ACTIVE_PREFIX = ARCHIVABLE_PREFIX;
const ARCHIVE_PREFIX = `archive(?:/${ARCHIVABLE_PREFIX})?`;
const STATE_PREFIX = new RegExp(`^(?:${ACTIVE_PREFIX}|${ARCHIVE_PREFIX})$`);

function validAttentionComponent(value: string): boolean {
  return value.length <= 160 && /^[A-Za-z0-9_:-]+(?:\.[A-Za-z0-9_:-]+)*$/.test(value);
}

function validAttentionRepoSegment(value: string): boolean {
  return value !== "." && !value.includes("..") && /^[A-Za-z0-9_.-]+$/.test(value);
}

function validAttentionRepository(owner: string, name: string): boolean {
  return `${owner}/${name}`.length <= 160
    && validAttentionRepoSegment(owner)
    && validAttentionRepoSegment(name);
}

function validAttentionPath(path: string): boolean {
  const parts = path.split("/");
  if (parts.length !== 5 || parts[0] !== "attention" || !parts[4].endsWith(".json")) return false;
  const id = parts[4].slice(0, -".json".length);
  return validAttentionComponent(parts[1])
    && validAttentionRepository(parts[2], parts[3])
    && validAttentionComponent(id);
}

function validAttentionPrefix(prefix: string): boolean {
  const parts = prefix.split("/");
  if (parts[0] !== "attention" || parts.length > 4) return false;
  if (parts.length === 1) return true;
  if (!validAttentionComponent(parts[1])) return false;
  if (parts.length === 2) return true;
  if (!validAttentionRepoSegment(parts[2]) || parts[2].length > 158) return false;
  return parts.length === 3 || validAttentionRepository(parts[2], parts[3]);
}

const ATTENTION_REQUIRED_FIELDS = [
  "schema_version", "workspace", "id", "repository", "target", "status", "kind", "question",
  "choices", "priority_class", "priority_reason", "safe_resume", "source", "source_generation",
  "created_at", "refreshed_at",
] as const;
const ATTENTION_ALLOWED_FIELDS = new Set([...ATTENTION_REQUIRED_FIELDS, "resolved_at"]);
const ATTENTION_PRIORITIES = new Set([
  "urgent-risk", "unblocks-work", "current-head-merge", "product-architecture",
]);
const ATTENTION_CAPABILITY_STATES = new Set(["available", "unavailable", "unknown"]);
const RFC3339_PATTERN = /^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-5][0-9])(?:[.]([0-9]+))?(?:[Zz]|([+-])([0-9]{2}):([0-9]{2}))$/;

function plainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Array.from(value).length <= maximum;
}

interface Rfc3339Instant {
  seconds: number;
  fraction: string;
}

function leapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysBeforeYear(year: number): number {
  return 365 * year + Math.floor((year + 3) / 4) - Math.floor((year + 99) / 100)
    + Math.floor((year + 399) / 400);
}

function rfc3339Time(value: unknown): Rfc3339Instant | null {
  if (typeof value !== "string" || value.length > 64) return null;
  const match = value.match(RFC3339_PATTERN);
  if (!match) return null;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fraction = "",
    offsetSign, offsetHourText = "0", offsetMinuteText = "0"] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const offsetHour = Number(offsetHourText);
  const offsetMinute = Number(offsetMinuteText);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || offsetHour > 23 || offsetMinute > 59) return null;
  const monthLengths = [31, leapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  const daysInMonth = monthLengths[month - 1];
  if (day < 1 || day > daysInMonth) return null;
  const daysBeforeMonth = monthLengths.slice(0, month - 1).reduce((sum, length) => sum + length, 0);
  const localSeconds = (daysBeforeYear(year) - daysBeforeYear(1970) + daysBeforeMonth + day - 1) * 86_400
    + hour * 3_600 + minute * 60 + second;
  const offsetMinutes = offsetHour * 60 + offsetMinute;
  return {
    seconds: localSeconds + (offsetSign === "+" ? -offsetMinutes : offsetMinutes) * 60,
    fraction: fraction.replace(/0+$/, ""),
  };
}

function compareRfc3339(left: Rfc3339Instant, right: Rfc3339Instant): number {
  if (left.seconds !== right.seconds) return left.seconds - right.seconds;
  const width = Math.max(left.fraction.length, right.fraction.length);
  return left.fraction.padEnd(width, "0").localeCompare(right.fraction.padEnd(width, "0"));
}

const URI_PCHAR = new Set("!$&'()*+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~");
const URI_REG_NAME_CHAR = new Set("!$&'()*+,-.0123456789;=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~");
const URI_USERINFO_CHAR = new Set([...URI_REG_NAME_CHAR, ":"]);
const URI_QUERY_OR_FRAGMENT_CHAR = new Set([...URI_PCHAR, "?"]);

function validUriChars(value: string, allowed: Set<string>): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index];
    if (character === "%") {
      if (!/^[0-9A-Fa-f]{2}$/.test(value.slice(index + 1, index + 3))) return false;
      index += 2;
    } else if (!allowed.has(character)) {
      return false;
    }
  }
  return true;
}

function validUriQuery(value: string): boolean {
  value = value.replace(/[\t\r\n]/g, "");
  for (let index = 0; index + 2 < value.length; index += 1) {
    if (value[index] === "%" && !/[0-9A-Fa-f]/.test(value[index + 1]) && !/[0-9A-Fa-f]/.test(value[index + 2])) {
      return false;
    }
  }
  return true;
}

function validIpv4(value: string): boolean {
  const octets = value.split(".");
  return octets.length === 4 && octets.every(
    (octet) => /^(?:0|[1-9][0-9]{0,2})$/.test(octet) && Number(octet) <= 255,
  );
}

function validIpv6(value: string): boolean {
  if ((value.match(/::/g) ?? []).length > 1) return false;
  const compressed = value.includes("::");
  const [leftText, rightText = ""] = value.split("::");
  const left = leftText === "" ? [] : leftText.split(":");
  const right = rightText === "" ? [] : rightText.split(":");
  if ([...left, ...right].some((part) => part === "")) return false;

  const parts = [...left, ...right];
  let groups = 0;
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part.includes(".")) {
      if (index !== parts.length - 1 || !validIpv4(part)) return false;
      groups += 2;
    } else {
      if (!/^[0-9A-Fa-f]{1,4}$/.test(part)) return false;
      groups += 1;
    }
  }
  return compressed ? groups < 8 : groups === 8;
}

function validIpLiteral(value: string): boolean {
  if (/^v[0-9A-Fa-f]+\.[!$&'()*+,\-.0-9:;=A-Z_a-z~]+$/.test(value)) return true;
  return validIpv6(value);
}

function validUriAuthority(value: string): boolean {
  const at = value.indexOf("@");
  if (at >= 0) {
    if (value.indexOf("@", at + 1) >= 0 || !validUriChars(value.slice(0, at), URI_USERINFO_CHAR)) return false;
    value = value.slice(at + 1);
  }

  if (value.startsWith("[")) {
    const close = value.indexOf("]");
    if (close < 0 || !validIpLiteral(value.slice(1, close))) return false;
    const port = value.slice(close + 1);
    return port === "" || /^:[0-9]*$/.test(port);
  }
  if (value.includes("[") || value.includes("]")) return false;
  const colon = value.lastIndexOf(":");
  if (colon >= 0) {
    if (!/^[0-9]*$/.test(value.slice(colon + 1)) || value.slice(0, colon).includes(":")) return false;
    value = value.slice(0, colon);
  }
  return validUriChars(value, URI_REG_NAME_CHAR);
}

function validAbsoluteUri(value: unknown): boolean {
  if (!boundedText(value, 2000)) return false;
  const match = value.match(/^([A-Za-z][A-Za-z0-9+.-]*):([\s\S]*)$/);
  if (!match) return false;
  let rest = match[2];
  if ([...rest].some((character) => character.charCodeAt(0) > 0x7f)) return false;

  const fragmentStart = rest.indexOf("#");
  if (fragmentStart >= 0) {
    if (rest.indexOf("#", fragmentStart + 1) >= 0) return false;
    if (!validUriChars(rest.slice(fragmentStart + 1), URI_QUERY_OR_FRAGMENT_CHAR)) return false;
    rest = rest.slice(0, fragmentStart);
  }

  const queryStart = rest.indexOf("?");
  const hierarchy = queryStart >= 0 ? rest.slice(0, queryStart) : rest;
  if (hierarchy !== "" && !hierarchy.startsWith("/")) {
    // Ruby treats a rootless component and everything through its query marker as one opaque value.
    return validUriChars(hierarchy, URI_PCHAR);
  }
  const validQuery = queryStart < 0 || validUriQuery(rest.slice(queryStart + 1));
  if (hierarchy.startsWith("//")) {
    const pathStart = hierarchy.indexOf("/", 2);
    const authority = pathStart >= 0 ? hierarchy.slice(2, pathStart) : hierarchy.slice(2);
    const path = pathStart >= 0 ? hierarchy.slice(pathStart) : "";
    return validQuery && validUriAuthority(authority) && validUriChars(path, URI_PCHAR);
  }
  if (hierarchy === "") return validQuery;
  if (hierarchy.startsWith("/")) {
    return validQuery && !hierarchy.startsWith("//") && validUriChars(hierarchy, URI_PCHAR);
  }
  return false;
}

function validAttentionSource(value: unknown): boolean {
  if (!plainObject(value)) return false;
  const required = ["provider", "host_id", "task_id", "last_seen_at", "capabilities"];
  const allowed = new Set([...required, "open_uri"]);
  if (!required.every((field) => Object.hasOwn(value, field))) return false;
  if (Object.keys(value).some((field) => !allowed.has(field))) return false;
  if (!boundedText(value.provider, 100) || !boundedText(value.host_id, 255) || !boundedText(value.task_id, 255)) {
    return false;
  }
  if (rfc3339Time(value.last_seen_at) === null) return false;
  if (Object.hasOwn(value, "open_uri") && !validAbsoluteUri(value.open_uri)) {
    return false;
  }
  if (!plainObject(value.capabilities)) return false;
  if (Object.keys(value.capabilities).sort().join(",") !== "native_open,prompt_forwarding") return false;
  return Object.values(value.capabilities).every(
    (capability) => typeof capability === "string" && ATTENTION_CAPABILITY_STATES.has(capability),
  );
}

function validAttentionRecord(path: string, value: unknown): value is Record<string, unknown> {
  if (!plainObject(value)) return false;
  if (!ATTENTION_REQUIRED_FIELDS.every((field) => Object.hasOwn(value, field))) return false;
  if (Object.keys(value).some((field) => !ATTENTION_ALLOWED_FIELDS.has(field))) return false;
  if (value.schema_version !== 1 || typeof value.workspace !== "string" || typeof value.id !== "string"
      || typeof value.repository !== "string") return false;
  const repositoryParts = value.repository.split("/");
  if (!validAttentionComponent(value.workspace) || !validAttentionComponent(value.id)
      || repositoryParts.length !== 2 || !validAttentionRepository(repositoryParts[0], repositoryParts[1])) return false;
  if (path !== `attention/${value.workspace}/${value.repository}/${value.id}.json`) return false;
  if (!boundedText(value.target, 2000) || !boundedText(value.kind, 100)
      || !boundedText(value.question, 4000) || !boundedText(value.priority_reason, 4000)
      || !boundedText(value.safe_resume, 4000)) return false;
  if (!Array.isArray(value.choices) || value.choices.length < 1 || value.choices.length > 10
      || !value.choices.every((choice) => boundedText(choice, 2000))) return false;
  if (typeof value.priority_class !== "string" || !ATTENTION_PRIORITIES.has(value.priority_class)) return false;
  if (value.status !== "open" && value.status !== "resolved") return false;
  if (typeof value.source_generation !== "number" || !Number.isSafeInteger(value.source_generation)
      || value.source_generation < 0) return false;
  if (!validAttentionSource(value.source)) return false;
  const createdAt = rfc3339Time(value.created_at);
  const refreshedAt = rfc3339Time(value.refreshed_at);
  if (createdAt === null || refreshedAt === null || compareRfc3339(refreshedAt, createdAt) < 0) return false;
  if (value.status === "resolved") {
    const resolvedAt = rfc3339Time(value.resolved_at);
    return resolvedAt !== null && compareRfc3339(resolvedAt, createdAt) >= 0;
  }
  return !Object.hasOwn(value, "resolved_at");
}

function validPath(path: string): boolean {
  const encoder = new TextEncoder();
  const archive = path.startsWith("archive/");
  const activePath = archive ? path.slice("archive/".length) : path;
  const maxPathBytes = archive ? MAX_ARCHIVE_STATE_PATH_BYTES : MAX_ACTIVE_STATE_PATH_BYTES;
  return encoder.encode(path).byteLength <= maxPathBytes
    && encoder.encode(activePath).byteLength <= MAX_ACTIVE_STATE_PATH_BYTES
    && (STATE_PATH.test(path) || validAttentionPath(path))
    && !path.includes("..")
    && !path.includes("//");
}

function validPrefix(prefix: string): boolean {
  return new TextEncoder().encode(prefix).byteLength <= MAX_ACTIVE_STATE_PATH_BYTES
    && (STATE_PREFIX.test(prefix) || validAttentionPrefix(prefix))
    && !prefix.includes("..")
    && !prefix.includes("//");
}

function globDescendantPrefix(prefix: string): string {
  return `${prefix}/*`;
}

function validScopePrefix(prefix: string): boolean {
  return prefix === "" || validPrefix(prefix) || validPath(prefix);
}

function exactStatePathScope(scope: string): boolean {
  if (!validPath(scope)) return false;
  // Keep these explicit record shapes in sync with STATE_PATH if the state grammar expands.
  const parts = scope.split("/");
  if (parts[0] === "archive") return true;
  switch (parts[0]) {
    case "claims":
      return parts.length === 4;
    case "heartbeats":
    case "batches":
      return parts.length === 2;
    case "events":
      return parts.length === 3;
    case "attention":
      return parts.length === 5;
    default:
      return false;
  }
}

function parsePrefixList(value: string): string[] | null {
  try {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;
    if (!parsed.every((item) => typeof item === "string" && validScopePrefix(item))) return null;
    return parsed;
  } catch {
    return null;
  }
}

function bearerToken(request: Request): string | null {
  const match = (request.headers.get("authorization") ?? "").match(/^Bearer (.+)$/i);
  return match?.[1] ?? null;
}

async function authenticate(token: string, env: Env): Promise<MachineAuth | null> {
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    "SELECT machine, read_prefixes, write_prefixes FROM machines WHERE token_hash = ? AND revoked_at IS NULL",
  ).bind(hash).first<{ machine: string; read_prefixes: string; write_prefixes: string }>();
  if (!row) return null;
  return {
    machine: row.machine,
    readPrefixes: parsePrefixList(row.read_prefixes) ?? [],
    writePrefixes: parsePrefixList(row.write_prefixes) ?? [],
  };
}

function scopeCoversPath(scope: string, path: string): boolean {
  if (scope === "") return true;
  if (path === scope) return true;
  return !exactStatePathScope(scope) && path.startsWith(`${scope}/`);
}

function scopeCoversListPrefix(scope: string, prefix: string): boolean {
  if (scope === "") return true;
  if (exactStatePathScope(scope)) return false;
  return prefix === scope || prefix.startsWith(`${scope}/`);
}

type ScopedListFilter = { kind: "directory"; scope: string } | { kind: "path"; scope: string };
type ListScopeFilter = { kind: "all" } | ScopedListFilter;

function listScopeFilter(scope: string, prefix: string): ListScopeFilter | null {
  if (scope === "") return { kind: "all" };
  if (scopeCoversListPrefix(scope, prefix)) return { kind: "all" };
  if (exactStatePathScope(scope)) {
    return scope.startsWith(`${prefix}/`) ? { kind: "path", scope } : null;
  }
  return scope.startsWith(`${prefix}/`) ? { kind: "directory", scope } : null;
}

function listScopeFilters(prefixes: string[], prefix: string): ScopedListFilter[] | null {
  const filters: ScopedListFilter[] = [];
  for (const scope of prefixes) {
    const filter = listScopeFilter(scope, prefix);
    if (!filter) continue;
    if (filter.kind === "all") return [];
    filters.push(filter);
  }
  return filters.length > 0 ? filters : null;
}

function canAccessPath(prefixes: string[], path: string): boolean {
  return prefixes.some((prefix) => scopeCoversPath(prefix, path));
}

function canDeletePath(prefixes: string[], path: string): boolean {
  if (path.startsWith("archive/")) return canAccessPath(prefixes, path);
  return canAccessPath(prefixes, path) && canAccessPath(prefixes, `archive/${path}`);
}

async function readJsonBody(
  request: Request,
  maxRequestBytes: number,
): Promise<{ body: unknown } | { response: Response }> {
  if (!request.body) return { response: json(400, { error: "invalid_json" }) };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maxRequestBytes) {
      await reader.cancel();
      return { response: json(413, { error: "payload_too_large" }) };
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return { body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { response: json(400, { error: "invalid_json" }) };
  }
}

async function getState(env: Env, path: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT data, version, updated_by FROM state WHERE path = ?")
    .bind(path).first<{ data: string; version: number; updated_by: string | null }>();
  if (!row) return json(404, { error: "not_found" });
  const body: { path: string; data: unknown; version: number; updated_by?: string } = {
    path,
    data: JSON.parse(row.data),
    version: row.version,
  };
  if (row.updated_by !== null) body.updated_by = row.updated_by;
  return json(200, body);
}

async function putState(request: Request, env: Env, path: string, machine: string): Promise<Response> {
  const maxStateBytes = path.startsWith("archive/") ? MAX_ARCHIVE_STATE_BYTES : MAX_STATE_BYTES;
  const maxRequestBytes = maxStateBytes + REQUEST_ENVELOPE_BYTES;
  // Best-effort pre-parse guard; the serialized-data cap below still handles absent lengths.
  const contentLength = request.headers.get("content-length");
  if (contentLength && /^\d+$/.test(contentLength)) {
    const requestBytes = Number.parseInt(contentLength, 10);
    if (!Number.isSafeInteger(requestBytes) || requestBytes > maxRequestBytes) {
      return json(413, { error: "payload_too_large" });
    }
  }

  const bodyResult = await readJsonBody(request, maxRequestBytes);
  if ("response" in bodyResult) return bodyResult.response;
  const body = bodyResult.body;
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { error: "missing_data" });
  }
  const payload = body as { data?: unknown };
  if (payload.data === undefined) return json(400, { error: "missing_data" });
  const data = JSON.stringify(payload.data);
  if (new TextEncoder().encode(data).byteLength > maxStateBytes) {
    return json(413, { error: "payload_too_large" });
  }
  const now = new Date().toISOString();
  const ifMatch = request.headers.get("if-match");
  const ifNoneMatch = request.headers.get("if-none-match");

  if (ifNoneMatch && ifNoneMatch !== "*") return json(400, { error: "invalid_if_none_match" });
  if (ifNoneMatch === "*") {
    const result = await env.DB.prepare(
      "INSERT INTO state (path, data, version, updated_at, updated_by) VALUES (?, ?, 1, ?, ?) ON CONFLICT (path) DO NOTHING",
    ).bind(path, data, now, machine).run();
    if (result.meta.changes === 0) return json(409, { error: "already_exists" });
    return json(201, { path, version: 1, updated_by: machine });
  }
  if (ifMatch) {
    if (!/^\d+$/.test(ifMatch)) return json(400, { error: "invalid_if_match" });
    const version = Number.parseInt(ifMatch, 10);
    if (!Number.isSafeInteger(version)) return json(400, { error: "invalid_if_match" });
    const result = await env.DB.prepare(
      "UPDATE state SET data = ?, version = version + 1, updated_at = ?, updated_by = ? WHERE path = ? AND version = ?",
    ).bind(data, now, machine, path, version).run();
    if (result.meta.changes === 0) return json(409, { error: "version_conflict" });
    return json(200, { path, version: version + 1, updated_by: machine });
  }
  return json(400, { error: "precondition_required" });
}

async function deleteState(request: Request, env: Env, path: string, machine: string): Promise<Response> {
  const ifMatch = request.headers.get("if-match");
  if (!ifMatch || !/^\d+$/.test(ifMatch)) return json(400, { error: "precondition_required" });
  const version = Number.parseInt(ifMatch, 10);
  if (!Number.isSafeInteger(version)) return json(400, { error: "invalid_if_match" });
  const result = await env.DB.prepare(
    "DELETE FROM state WHERE path = ? AND version = ?",
  ).bind(path, version).run();
  if (result.meta.changes === 0) return json(409, { error: "version_conflict" });
  return json(200, { path, deleted: true, updated_by: machine });
}

async function listState(
  env: Env,
  prefix: string,
  searchParams: URLSearchParams,
  auth: MachineAuth,
): Promise<Response> {
  if (!validPrefix(prefix)) {
    return json(400, { error: "invalid_prefix" });
  }
  const scopeFilters = listScopeFilters(auth.readPrefixes, prefix);
  if (scopeFilters === null) return json(403, { error: "forbidden" });
  const status = searchParams.get("status");
  if (status !== null && (status !== "open" || !validAttentionPrefix(prefix))) {
    return json(400, { error: "invalid_status" });
  }
  const limitParam = searchParams.get("limit");
  let limit: number | null = null;
  if (limitParam !== null) {
    if (!/^\d+$/.test(limitParam)) return json(400, { error: "invalid_limit" });
    limit = Number.parseInt(limitParam, 10);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_LIST_LIMIT) {
      return json(400, { error: "invalid_limit" });
    }
  }
  const cursor = searchParams.get("cursor");
  if (cursor !== null && (!validPath(cursor) || !cursor.startsWith(`${prefix}/`))) {
    return json(400, { error: "invalid_cursor" });
  }
  const clauses = ["path GLOB ?"];
  const binds: (string | number)[] = [globDescendantPrefix(prefix)];
  if (scopeFilters.length > 0) {
    const scopeClauses = scopeFilters.map((filter) => {
      if (filter.kind === "path") {
        binds.push(filter.scope);
        return "path = ?";
      }
      binds.push(globDescendantPrefix(filter.scope));
      return "path GLOB ?";
    });
    clauses.push(`(${scopeClauses.join(" OR ")})`);
  }
  let nextCursor: string | undefined;
  let entries: Array<{ path: string; data: Record<string, unknown>; version: number; updated_by?: string }> = [];
  if (status !== null) {
    let scanCursor = cursor;
    while (true) {
      const pageClauses = [...clauses];
      const pageBinds = [...binds];
      if (scanCursor !== null) {
        pageClauses.push("path > ?");
        pageBinds.push(scanCursor);
      }
      const sql = `SELECT path, data, version, updated_by FROM state WHERE ${pageClauses.join(" AND ")}`
        + " ORDER BY path LIMIT ?";
      pageBinds.push(MAX_LIST_LIMIT);
      const page = await env.DB.prepare(sql).bind(...pageBinds)
        .all<{ path: string; data: string; version: number; updated_by: string | null }>();
      const pageRows = page.results ?? [];
      for (const row of pageRows) {
        const data: unknown = JSON.parse(row.data);
        if (!validAttentionRecord(row.path, data)) return json(500, { error: "invalid_attention_status" });
        if (data.status === status && (limit === null || entries.length <= limit)) {
          entries.push({
            path: row.path,
            data,
            version: row.version,
            ...(row.updated_by === null ? {} : { updated_by: row.updated_by }),
          });
        }
      }
      if (pageRows.length < MAX_LIST_LIMIT) break;
      scanCursor = pageRows[pageRows.length - 1]?.path ?? null;
    }
    if (limit !== null && entries.length > limit) {
      entries = entries.slice(0, limit);
      nextCursor = entries[entries.length - 1]?.path;
    }
  } else {
    if (cursor !== null) {
      clauses.push("path > ?");
      binds.push(cursor);
    }
    let sql = `SELECT path, data, version, updated_by FROM state WHERE ${clauses.join(" AND ")} ORDER BY path`;
    if (limit !== null) {
      sql += " LIMIT ?";
      binds.push(limit + 1);
    }
    const rows = await env.DB.prepare(sql).bind(...binds)
      .all<{ path: string; data: string; version: number; updated_by: string | null }>();
    const results = rows.results ?? [];
    entries = results.map((row) => ({
      path: row.path,
      data: JSON.parse(row.data) as Record<string, unknown>,
      version: row.version,
      ...(row.updated_by === null ? {} : { updated_by: row.updated_by }),
    }));
    if (limit !== null && entries.length > limit) {
      entries = entries.slice(0, limit);
      nextCursor = entries[entries.length - 1]?.path;
    }
  }
  return json(200, {
    entries,
    ...(scopeFilters.length > 0 ? { filtered: true } : {}),
    ...(nextCursor ? { next_cursor: nextCursor } : {}),
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/v1/health") {
      return json(200, { status: "ok" });
    }
    const token = bearerToken(request);
    if (!token) {
      return json(401, { error: "unauthorized" });
    }
    const auth = await authenticate(token, env);
    if (!auth) {
      return json(401, { error: "unknown_token" });
    }
    if (url.pathname === "/v1/whoami") {
      if (request.method !== "GET") return json(405, { error: "method_not_allowed" });
      return json(200, {
        machine: auth.machine,
        read_prefixes: auth.readPrefixes,
        write_prefixes: auth.writePrefixes,
      });
    }
    if (url.pathname === "/v1/state") {
      if (request.method === "GET") {
        return listState(env, url.searchParams.get("prefix") ?? "", url.searchParams, auth);
      }
      return json(405, { error: "method_not_allowed" });
    }
    if (url.pathname.startsWith("/v1/state/")) {
      let path: string;
      try {
        path = decodeURIComponent(url.pathname.slice("/v1/state/".length));
      } catch {
        return json(400, { error: "invalid_path" });
      }
      if (!validPath(path)) return json(400, { error: "invalid_path" });
      if (request.method === "GET") {
        if (!canAccessPath(auth.readPrefixes, path)) return json(403, { error: "forbidden" });
        return getState(env, path);
      }
      if (request.method === "PUT") {
        if (!canAccessPath(auth.writePrefixes, path)) return json(403, { error: "forbidden" });
        return putState(request, env, path, auth.machine);
      }
      if (request.method === "DELETE") {
        if (path.startsWith("attention/")) {
          if (!canAccessPath(auth.writePrefixes, path)) return json(403, { error: "forbidden" });
          return json(405, { error: "method_not_allowed" });
        }
        if (!canDeletePath(auth.writePrefixes, path)) return json(403, { error: "forbidden" });
        return deleteState(request, env, path, auth.machine);
      }
      return json(405, { error: "method_not_allowed" });
    }
    return json(404, { error: "route_not_found" });
  },
};
