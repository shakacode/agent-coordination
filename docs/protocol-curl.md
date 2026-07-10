# Worker State Protocol with `curl`

Use the `agent-coord` CLI for normal coordination. These requests document the
lower-level Worker state protocol for integration development and diagnostics.
Run write examples only against a local or staging Worker and a disposable path.

The examples deliberately contain placeholders rather than a deployed host,
credential, repository, or target. Set the values in a private shell; never add
the substituted commands, token, or responses to source control or public logs.

```bash
export AGENT_COORD_API_URL='https://<worker-host>'
export AGENT_COORD_API_TOKEN='<machine-token>'
export STATE_PATH='claims/<owner>/<repository>/<target>.json'
```

The health endpoint does not require authentication:

```bash
curl --fail-with-body --silent --show-error \
  "$AGENT_COORD_API_URL/v1/health"
```

Every state read and write requires a bearer token. A token can read or write
only paths covered by its configured scopes. List a prefix with URL-encoded
query parameters:

```bash
curl --fail-with-body --silent --show-error --get \
  --header "Authorization: Bearer $AGENT_COORD_API_TOKEN" \
  --data-urlencode 'prefix=claims/<owner>/<repository>' \
  --data-urlencode 'limit=100' \
  "$AGENT_COORD_API_URL/v1/state"
```

Read one exact record. A successful response contains `path`, `data`, and a
numeric `version` used for compare-and-swap updates:

```bash
STATE_RESPONSE=$(curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $AGENT_COORD_API_TOKEN" \
  "$AGENT_COORD_API_URL/v1/state/$STATE_PATH")
printf '%s\n' "$STATE_RESPONSE"
STATE_VERSION=$(printf '%s' "$STATE_RESPONSE" | ruby -rjson -e 'print JSON.parse($stdin.read).fetch("version")')
```

Create a record only when its path does not exist. Keep the `data` envelope;
the Worker rejects writes without an explicit precondition:

```bash
curl --fail-with-body --silent --show-error --request PUT \
  --header "Authorization: Bearer $AGENT_COORD_API_TOKEN" \
  --header 'Content-Type: application/json' \
  --header 'If-None-Match: *' \
  --data '{"data":{"schema_version":1,"repo":"<owner>/<repository>","target":"<target>","agent_id":"curl-demo","status":"active"}}' \
  "$AGENT_COORD_API_URL/v1/state/$STATE_PATH"
```

Update an existing record only when its current numeric version still matches.
First repeat the exact read above so `STATE_VERSION` is current:

```bash
curl --fail-with-body --silent --show-error --request PUT \
  --header "Authorization: Bearer $AGENT_COORD_API_TOKEN" \
  --header 'Content-Type: application/json' \
  --header "If-Match: $STATE_VERSION" \
  --data '{"data":{"schema_version":1,"repo":"<owner>/<repository>","target":"<target>","agent_id":"curl-demo","status":"released"}}' \
  "$AGENT_COORD_API_URL/v1/state/$STATE_PATH"
```

Relevant responses are:

- `401` for a missing or invalid token.
- `403` when the token scope does not cover the requested path.
- `404` when an exact read has no record.
- `400` for an invalid or overlong path/prefix, malformed body, or missing precondition.
- `409` when create finds an existing record or an update uses a stale version.
- `413` when the request or serialized state exceeds protocol size limits.

Treat a `409` as contention: read again and reconsider the coordination action
instead of retrying the old write blindly. Prefer `agent-coord` for claims and
heartbeats because it applies the protocol's lease and liveness rules above
these raw state operations.
