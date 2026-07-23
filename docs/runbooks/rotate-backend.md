# Rotate the D1 Coordination Backend

Use this runbook whenever the coordination Worker moves to a replacement D1
database. A database rotation does not carry machine tokens into the new
database automatically. Every consumer must receive a newly provisioned token
and be restarted before it can read coordination state again.

## Before the cutover

Record the replacement database name, the Worker environment being changed,
and every machine or service that reads or writes coordination state. For each
consumer, record its required read and write prefixes and how it is restarted.
Do not record token values in the inventory.

## Rotate and migrate the database

Create the replacement database, put its generated `database_id` in the
deployment-specific Worker configuration, and apply every checked-in migration
before deploying the Worker:

```bash
cd worker
npx wrangler d1 create <database-name>
# Update the deployment's D1 binding to the printed database_id.
npx wrangler d1 migrations apply <database-name> --remote
npx wrangler deploy
cd ..
```

Verify that the deployed Worker's `/v1/health` endpoint succeeds before
provisioning consumers.

## Re-provision every machine

Run one command per machine. Use only the prefixes that machine needs:

```bash
worker/bin/provision-token <machine-name> \
  --database <database-name> \
  --rotate \
  --read-prefix <read-prefix> \
  --write-prefix <write-prefix>
```

For a trusted operator or dashboard that intentionally needs every state path,
replace the prefix flags with `--all-state`.

The plaintext token is printed once and is not stored by the provisioning
script. Before closing the terminal, write the Worker URL and new token to the
consumer's private environment file and keep it mode `600`:

```bash
export AGENT_COORD_ENV_FILE="${AGENT_COORD_ENV_FILE:-$HOME/.config/agent-coord/env}"
mkdir -p "$(dirname "$AGENT_COORD_ENV_FILE")"
umask 077
touch "$AGENT_COORD_ENV_FILE"
chmod 600 "$AGENT_COORD_ENV_FILE"
# Add AGENT_COORD_API_URL and AGENT_COORD_API_TOKEN without committing the file.
```

Never paste token values into issues, logs, shell history, or the repository.
If a printed token is lost before it is stored, run the provisioning command
again with `--rotate`; do not try to recover the old value from D1 because only
its SHA-256 hash is stored.

## Restart and verify consumers

Restart every long-running consumer so it reloads the environment file. A shell
that has not sourced it falls back to the implicit local state root; because the
env file configures `AGENT_COORD_API_URL`, `agent-coord` refuses writes there
with exit `2` and `agent-coord doctor` reports `status: split_brain` naming the
file. Source the file (below) rather than working around that stop; use
`--state-root PATH` or `AGENT_COORD_LOCAL=1` only for a deliberate local run.
For the operator dashboard the restart is normally:

```bash
agent-dashboard restart
```

In an operator shell, load the same Worker URL and token, then run the deep
diagnostic:

```bash
set -a
. "$AGENT_COORD_ENV_FILE"
set +a
agent-coord doctor --deep
```

The command must report `ok` or `filtered` for each intended resource and show
the expected authenticated machine and scopes. `forbidden` is acceptable only
for a resource the consumer is intentionally not allowed to read. A `401`
names the failing resource and prints this recovery command:

```bash
worker/bin/provision-token <machine-name> --database <database-name> --rotate \
  --read-prefix <prefix> [--write-prefix <prefix> ...]
```

Reuse the machine's intended prefixes from the pre-cutover inventory. Use
`--all-state` only when that machine was already intentionally unrestricted.
Update the environment file with the newly printed token without replacing
unrelated settings, restart the consumer, and rerun
`agent-coord doctor --deep`. Finally, confirm the dashboard or other consumer
shows live claims, heartbeats, batches, and events.
