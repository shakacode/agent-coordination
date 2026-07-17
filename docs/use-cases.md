# Who This Is For: Local-First Agent Coordination

Cloud agent platforms solve fleet coordination by owning the fleet. This
project solves it for engineers who **run state-of-the-art desktop agents on
their own machines** — because that's where the best models meet the lowest
cost and the fastest feedback — and who still need the thing the cloud
platforms provide: knowing what is running where, what owns what, and what
happened to work when a session dies.

## Use case 1: SOTA desktop apps — Codex and Claude Code, side by side

The strongest coding agents ship as desktop/CLI apps first. Running Codex and
Claude Code locally means frontier models, your hardware, your API plans, no
per-seat orchestration fees — and zero built-in awareness of each other. Two
apps from two vendors will happily work the same issue, push the same branch,
and review each other's half-finished commits. The coordination plane is the
missing referee: **claims** make cross-vendor mutual exclusion real, and
**thread handles** let you match a dashboard row to a chat in either app's
sidebar. Nothing here requires choosing a vendor; the CLI contract is
host-neutral by design.

## Use case 2: Worktrees — parallel lanes on one machine

`git worktree` solves two *sessions* editing one *checkout* — and a new class
of desktop apps industrializes the pattern: [Conductor](https://conductor.build)
runs parallel Claude Code sessions in isolated worktrees, and
[Orca](https://www.onorca.dev) orchestrates multiple coding-agent sessions the
same way. These are first-class host environments for this plane: coordination
runs *inside* their sessions (claims, handles, and lane-context files in the
worktrees they manage), because the worktree layer still does not solve two
sessions working one *branch or issue* — nothing stops you from starting the
same lane in two apps an hour apart. Claims extend the worktree idea
one level up: a worktree isolates the working directory, a **claim isolates the
target**. The batch rules pair them: claim before worktree, one lane = one
worktree = one claim, and a second session that tries the same target gets
`CLAIM_REFUSED` with the holder named instead of a silent collision.

## Use case 3: Multiple machines — and switching between them

A desktop at the office, a laptop at the beach™, both running agents: the
coordination questions become "which machine is working #4123?" and "how do I
move this PR's work to the other machine without racing myself?" Per-machine
tokens give every record **machine attribution**; heartbeats carry the **host**
(Codex vs Claude Code) so the dashboard can answer *which machine, which app,
which chat*. Switching is an explicit, cheap operation instead of a hope:
`release --handoff-to ... --handoff-note ...` on machine A records branch, PR,
phase, and next steps as a structured resume note; machine B then claims the same
target — or **supersedes** when machine A's session is dead but its lease isn't.
It's the worktree insight again, applied across machines: make the ownership
boundary explicit and the switch becomes routine.

### Use case 3b: Plan windows — cap-aware work, cross-host failover

Both vendors meter subscriptions (5-hour windows, weekly caps). When one app
hits its cap, every lane it hosts stalls at once — and without limit tracking
that looks identical to several broken workers. The coordination plane records
cap state per machine+app pair, shows the reset countdown, and offers the move
that actually helps: **hand the work item to the other vendor** — release with
`--handoff-to` and `--handoff-note`, re-claim from the other app, keep going on
the same branch and PR. Claims, branches, and PRs are host-agnostic, so switching
a work item from Codex to Claude Code mid-PR (or back) is a routine handoff, not
a restart.

A boundary worth stating plainly: this plane **respects vendor limits**. It
surfaces caps and routes work to genuinely separate budget pools — the other
vendor's plan, or a different person's account on a team. It never rotates or
pools accounts within a vendor, and the launcher stops at caps rather than
scheduling around them. Making your paid window count is the feature;
evading it is permanently out of scope.

## Use case 4: Work can get lost

Local agent sessions die undramatically: a chat window closed, a context
compaction, a laptop reboot, a crashed app. Whatever lived only in that chat's
transcript — the batch instructions, the target list, "what was I doing" — is
gone. The coordination plane is deliberately designed so **nothing important
lives only in a chat**: batch instructions are registered *before* launch,
claims record branch and PR, phase heartbeats record how far work got, and
handoffs record what's next. Recovery from any dead session is: read the lane's
record, supersede the claim, continue. The dashboard's job is the inverse —
surfacing lanes whose sessions went quiet *before* you notice a PR sat idle for
a day.

## Use case 5: Pairing — two humans, one fleet

A common working mode: two developers side by side, both rapidly launching
agentic tasks across the same repos — many small lanes per hour, mixed hosts,
mixed machines. Everything above compounds here: claims stop the two humans
from double-working a target just as they stop two chats; machine tokens carry
an **operator** identity so every lane answers "whose is this?"; and the
dashboard becomes the shared source of truth that replaces shoulder-taps.

This mode also exposes the sharpest gap in the host apps today: **chat search
cannot find sessions by PR number**. When a sub-agent opened PR #4123 an hour
ago, neither operator can search their sidebar for `4123` and find the thread.
The dashboard is the index the chats lack: search any reference — PR number,
issue number, branch, thread handle — and get the lane row with its handle,
machine, host app, operator, and phase. One lookup answers "who has it, where,
and how far along."

## Use case 6: Two technical leads clearing a PR portfolio together

Pairing is not always two people working on one change. A second high-leverage
mode is two senior or staff developers jointly owning a repository-wide
outcome: for example, Justin and Robert dividing Justin's open HiChee pull
requests, bringing each one to a defensible final state, and merging the ones
that still belong.

This is different from a one-operator agent batch:

- The starting inventory is a portfolio of existing PRs, not a list of new
  issues to implement.
- Two humans make scope, sequencing, and product judgments. Agents work under
  those humans; they do not replace the accountable operator.
- A work owner, an independent reviewer, and the person authorized to merge may
  be different people.
- Ownership must survive chats, machines, worktrees, and a handoff between the
  two developers.
- The shared outcome is not "all workers stopped." Every PR must end in an
  explicit state such as merged, ready but awaiting merge authority, waiting on
  checks or review, externally blocked, needs a human decision, or closed with
  evidence that it should not land. The workflow's current human-facing
  vocabulary needs an explicit mapping for that last case because
  `no-pr-evidence` describes work where no PR was created, not an existing PR
  intentionally closed without merge.

### The shared operating loop

1. **Connect both developers to one coordination workspace.** Each developer
   uses a distinct machine credential, stable `operator` identity, and stable
   machine id. Both verify the same backend and repository scope before either
   starts work. The dashboard remains read-only shared visibility; secrets and
   machine tokens are never copied into a batch manifest or chat.
2. **Freeze an exact portfolio snapshot.** Query the requested GitHub scope
   (for example, open PRs authored by one maintainer), record the query and
   snapshot time, and materialize exact PR numbers in a registered batch. New
   matching PRs go into a later reconciliation pass rather than silently
   changing the active batch.
3. **Triage before assigning.** Classify each PR as keep-and-finish, review
   only, superseded/duplicate, needs a product decision, externally blocked, or
   `UNKNOWN`. Record dependencies and merge order. Draft status alone does not
   decide whether a PR is valuable; a clean merge status alone does not prove
   readiness.
4. **Assign human responsibility separately from agent ownership.** Every lane
   names an accountable work operator, an independent review operator when
   required, and merge authority. The lane's agent id still owns the execution
   claim. This keeps "Robert is responsible for this PR" distinct from "agent
   `hichee-pr-9812-review` currently holds this claim."
5. **Claim before mutation.** A developer or their agent acquires the exact PR
   target before updating its branch, comments, labels, review state, or merge
   state. A live or stale claim held by the other operator is a hard exclusion,
   not an invitation to work around the holder.
6. **Work to a safe checkpoint.** The active operator updates phase, branch,
   PR URL, thread handle, and blockers at meaningful transitions. Existing-PR
   lanes normally run live review/readiness checks, address verified feedback,
   validate the current head, and update the PR evidence rather than creating a
   replacement PR by default.
7. **Use the other lead as the judgment boundary.** Cross-review is most
   valuable for intent, risk, scope, and merge-readiness judgment. Mechanical
   evidence collection may be delegated, but the independent reviewer must not
   be the same agent instance that made the change. A reviewer does not mutate
   a claimed PR unless the lane explicitly transfers work ownership.
8. **Handoff explicitly.** The current holder releases with `handoff_to` and a
   resume note containing the branch, current head, checks run, review state,
   blocker, and next action. The recipient reads that durable state and then
   claims the target. Chat messages and GitHub assignees may support the
   handoff, but neither is the mutual-exclusion mechanism.
9. **Reconcile from the dashboard.** Both developers use the same portfolio
   view to find unassigned work, active claims, review queues, stale or dead
   lanes, handoffs awaiting acceptance, mergeable items, and state whose source
   is `UNKNOWN`. The dashboard explains the source and age of each status and
   links back to the PR and agent thread.
10. **Close the portfolio, not just the sessions.** Each lane records a
    terminal closeout or a precise nonterminal blocker. The portfolio is closed
    only when every exact target has a final disposition and no unowned
    follow-up or silent `UNKNOWN` remains.

### Minimum portfolio record

The registered batch is the durable agreement between the two developers. For
this use case, each lane needs the following logical fields. Existing generic
metadata may carry them during a pilot; fields that become interoperable
protocol surface should be added to the published state contract before other
consumers depend on them.

| Field | Meaning |
| --- | --- |
| `repo` + `target` | Exact PR identity; the target never means "whatever matches the query now." |
| `operator` | Human accountable for moving the PR to its next disposition. |
| `owner` | Agent/session id expected to acquire the execution claim. |
| `review_operator` | Human accountable for an independent readiness judgment, or a recorded reason it is not required. |
| `merge_authority` | `none`, `ask`, or `auto_merge_when_gates_pass`. |
| `depends_on` | Other lanes or merges that must finish first. |
| `status` + `phase` | Planned/active lifecycle and the current execution phase. |
| `thread_handle`, `branch`, `pr_url` | Routes from the portfolio row to the working context. |
| `handoff_to` + `handoff_note` | Durable transfer destination and resume evidence. |
| `terminal`, `evidence_url` | Final disposition and replayable closeout evidence. |

The portfolio also retains the source query, snapshot time, exact target list,
batch objective, repository, and default merge authority. Operator identity is
an explicit configured id; the system must not guess that a GitHub login,
machine credential, and display name refer to the same person.

### Product requirements

- **R1 — Shared identity:** both developers can prove that they are reading and
  writing the same workspace while records retain operator, machine, host app,
  and agent/session attribution.
- **R2 — Exact inventory:** an author/filter-based discovery produces a
  timestamped exact target list, reports excluded near-matches, and never adds a
  later match to an active batch without an explicit reconciliation action.
- **R3 — Distinct responsibilities:** the read model distinguishes accountable
  work operator, current claim holder, independent reviewer, and merge
  authority. Missing required responsibility is visible as `UNKNOWN`.
- **R4 — Exclusive mutation:** when one operator has a live or stale claim on a
  PR, a second operator's mutation lane is refused with holder and liveness
  evidence.
- **R5 — Review-safe collaboration:** a review-only operator can inspect and
  report without stealing the mutation claim; changing the PR requires an
  explicit assignment or handoff.
- **R6 — Durable handoff:** the recipient can resume from backend state after
  losing all chat context, and the old and new holders cannot both mutate the
  PR.
- **R7 — Explainable portfolio view:** either developer can filter by operator,
  responsibility, state, review need, merge readiness, or handoff status and can
  see status source, freshness, PR link, and thread handle.
- **R8 — Fail-closed readiness:** missing or stale CI, review, QA, coordination,
  dependency, or merge-ledger facts remain `UNKNOWN` or nonterminal; they never
  become an optimistic ready state.
- **R9 — Explicit closeout:** every target ends in the workflow's canonical
  final-state vocabulary with evidence, including a defined state or mapping for
  an existing PR intentionally closed without merge, and portfolio completion
  fails while any target lacks a disposition.
- **R10 — Easy second-developer setup:** a new collaborator can install the CLI
  and skills, receive a scoped machine credential through a private channel,
  set stable machine/operator identity, verify the stack, open the scoped
  dashboard, and claim a smoke-test target from one short runbook.

### Design decisions

- **D1 — Treat the portfolio as a registered batch (R2, R3, R7, R9).** Reusing
  the existing batch, lane, dependency, event, and closeout model preserves one
  coordination primitive. A separate portfolio store would duplicate target
  identity and liveness joins.
- **D2 — Separate human responsibility from the claim holder (R1, R3–R6).** A
  stable operator id names the accountable developer; an agent/session id owns
  the claim. Using either field for both meanings would make agent replacement
  or cross-review look like a human ownership change.
- **D3 — Freeze discovery into exact targets (R2, R4, R8, R9).** A dynamic
  author query is useful for reconciliation but unsafe as a standing mutation
  scope. Snapshot drift is reported, not auto-enrolled.
- **D4 — Keep the protocol dashboard read-only (R4, R5, R7, R8).** Mutation,
  review decisions, and merges stay in authenticated developer/agent sessions
  where repository instructions and claim gates can be enforced. A future
  product-plane UI may revisit this boundary without weakening the protocol
  dashboard.
- **D5 — Compose skills before adding a new one (R5, R8–R10).** Triage,
  readiness, address-review, batch execution, and closeout already own the
  safety rules. A recipe is cheaper to test and exposes which repeated steps,
  if any, justify a dedicated portfolio skill after the pilot.
- **D6 — Roll out with an intentionally mixed pilot (R6–R10).** A clean PR
  alone would prove the happy path but not collision refusal, CI/review waiting,
  conflict handling, human decisions, or handoff recovery.

### Executable delivery sequence

| Task | Repository or scope | Requirements | Dependencies | Done condition |
| --- | --- | --- | --- | --- |
| **T1 — Contract fixture and scenario** | `agent-coordination`: `sim/`, `test/`, `docs/` | R1–R6, R8, R9 | None | A sanitized two-operator fixture and deterministic test exercise registration, claim refusal, review-only observation, handoff, recipient claim, and terminal closeout. |
| **T2 — Responsibility metadata contract** | `agent-coordination`: `bin/agent-coord`, `contracts/`, `schema/`, `worker/` | R2, R3, R7–R9 | T1 | Additive fields and status behavior are documented, validated, round-trip through the CLI/backend, and remain compatible with older records. |
| **T3 — Second-developer smoke setup** | `agent-coordination`: CLI/demo and operator runbooks | R1, R10 | T1 | A scoped credential can run doctor and a non-production two-operator smoke scenario without printing secrets or touching live targets. |
| **T4 — Portfolio read model** | `agent-coordination-dashboard`: `src/server/state/`, `src/shared/` | R2, R3, R7–R9 | T2 | Tests show exact batch targets joined to GitHub, claims, handoffs, responsibilities, and canonical dispositions with fail-closed `UNKNOWN`. |
| **T5 — Portfolio queues and drift UI** | `agent-coordination-dashboard`: `src/client/`, server GitHub/state joins | R2, R3, R7, R8 | T4 | Both operators can filter their work/review/handoff queues, see unassigned and stale work, and see source-query drift with provenance and age. |
| **T6 — Two-lead workflow recipe** | `agent-workflows`: triage, planning, review/readiness, and closeout docs/skills | R2–R10 | T1; finalize after T2 | A portable documented entry path freezes scope, assigns human and agent responsibilities, uses existing claim/review/readiness skills, defines intentionally-closed PR closeout, and emits canonical aggregate closeout. |
| **T7 — Install and verify handoff** | `agent-workflows`: installation, upgrade, and stack-doctor surfaces | R1, R10 | T3, T6 | The consumer setup path installs or verifies the CLI, dashboard lifecycle, shared skills, repo seam, identity, backend scope, and copyable smoke commands. |
| **T8 — HiChee seam and pilot manifest** | private HiChee `.agents/` seam and private coordination state | R1–R10 | T2–T7 | Repo policy resolves without `UNKNOWN`, both separately credentialed operators see the same exact small pilot, and no secret or live state is committed. |
| **T9 — Run and evaluate the pilot** | HiChee operations | R4–R10 | T8 | The mixed PR wave meets every pilot success criterion; friction and missing telemetry are recorded against the responsible repository. |
| **T10 — Scale or graduate** | Cross-repo product decision; file scope `UNKNOWN` until T9 | R7, R9, R10 | T9 | Evidence decides whether to expand the recipe as-is, add a dedicated skill, or move assignment actions into a separate authenticated product plane. |

T1, T3, and an early draft of T6 can proceed in parallel after their shared
field vocabulary is agreed. T4 requires the T2 contract. T5 follows T4. T8 and
T9 are deliberately last because live HiChee work should validate a coherent
stack, not substitute for cross-repo contract tests.

### Implementation plan by layer

#### Agent Coordination protocol and CLI

1. **Document and test the pilot contract (R1–R6, R8–R10).** Publish a
   sanitized two-operator fixture and a deterministic scenario covering
   inventory registration, assignment, claim refusal, review-only observation,
   handoff, takeover, and terminal closeout. Do not put live HiChee state or
   credentials in this repository.
2. **Standardize responsibility metadata (R2, R3, R9).** Decide which fields
   remain batch-only planning metadata and which become published protocol
   fields. At minimum preserve and expose `operator`, `review_operator`,
   `merge_authority`, source query, and snapshot time. Make the change additive
   for older producers and consumers.
3. **Make handoff acceptance inspectable (R5, R6).** Status should distinguish
   a released handoff awaiting the named recipient from an ordinary unowned
   target. Claim fencing remains authoritative during transfer.
4. **Add an onboarding smoke path (R1, R10).** Extend doctor/demo behavior or a
   narrow runbook so a second developer can verify backend identity and scope,
   then exercise a non-production target without exposing the token.

#### Agent Coordination Dashboard

1. **Add a portfolio projection (R2, R3, R7–R9).** Build a saved/read-only
   view over an exact registered batch with columns for work operator, claim
   holder/liveness, review operator, merge authority, dependency, current
   readiness, handoff state, and final disposition.
2. **Add responsibility queues (R3, R7).** Offer explainable filters such as
   "Justin owns," "Robert owns," "needs Robert review," "handoff to me,"
   "unassigned," "stale/dead," and "ready to merge." Use configured operator
   ids rather than hard-coded names.
3. **Expose provenance and drift (R2, R7, R8).** Show the discovery query and
   snapshot time, flag open PRs that now match but are outside the snapshot,
   and label every derived readiness value with its source and age. GitHub or
   backend failures render visible `UNKNOWN` states.
4. **Keep the control boundary (R4, R5).** The protocol dashboard stays
   observability-first. Copyable commands or skill prompts may help an operator
   claim, hand off, review, or merge in an agent session; the dashboard does not
   edit code, steal claims, approve reviews, or merge PRs.

#### Agent Workflows skills

1. **Add a two-lead portfolio recipe (R2–R10).** Compose existing live triage,
   PR readiness, address-review, claim, handoff, QA, and closeout rules into one
   documented entry path for "divide these open PRs between us and land what
   should land." Prefer composition over a new monolithic skill until the
   pilot shows a distinct reusable trigger.
2. **Extend planning output with human responsibilities (R3, R5).** Batch plans
   and goal prompts should carry work operator, review operator, merge
   authority, and review-only versus mutation scope separately from agent/lane
   ownership.
3. **Add portfolio reconciliation (R2, R7–R9).** A read-only planning pass
   compares live GitHub, the frozen batch, and coordination state; it reports
   new matches, closed/merged targets, stale ownership, missing reviews, and
   `UNKNOWN` evidence without silently changing the active scope.
4. **Teach closeout to aggregate across operators (R6, R9).** Per-PR final
   states remain canonical; define the existing-PR intentionally-closed case
   rather than misusing `no-pr-evidence`. The portfolio summary groups by
   accountable operator and names every remaining owner/action rather than
   treating a worker handoff as completion.

#### HiChee adoption

1. Configure the repository's workflow seam to select the shared backend,
   readiness/review policy, trusted actors, base branch, and merge-ledger rules.
2. Give each developer a separately scoped backend credential and stable local
   operator/machine configuration through private setup, never through GitHub
   or committed files.
3. Start with a small, representative exact PR wave: one clean documentation
   PR, one CI-failing PR, one conflicted PR, and one draft or needs-decision PR.
4. Run the full assignment, claim, cross-review, handoff, readiness, merge (when
   authorized), and closeout loop. Record friction and missing telemetry.
5. Only after that pilot, expand to the remaining frozen portfolio and decide
   whether the recipe deserves a dedicated skill or product-plane write UI.

### Non-goals and guardrails

- GitHub assignees, reviewers, labels, and project fields do not replace the
  coordination claim. They may mirror responsibility for human visibility.
- The protocol does not infer personnel identity from names or GitHub handles.
- The read-only protocol dashboard does not become an agent launcher or merge
  console for this use case.
- "All open PRs" is never a permanently expanding mutation scope. Discovery is
  frozen into exact targets and refreshed deliberately.
- The system does not auto-merge because two agents agree. Repository policy,
  current-head gates, independent review, explicit authority, and release rules
  still apply.
- The first pilot does not require multi-tenant product accounts, org SSO, or a
  hosted writable product plane.

### Pilot success criteria

- Both developers complete setup from the runbook without sharing one token or
  editing committed secrets.
- The same exact portfolio and responsibility split appears on both machines.
- A deliberate competing mutation attempt is refused and names the holder.
- A review-only pass produces evidence without changing ownership.
- A handoff resumes on the second machine from durable state alone.
- The dashboard answers who owns the next action for every pilot PR and shows
  visible `UNKNOWN` for unavailable evidence.
- Every pilot PR finishes with one canonical disposition, and the aggregate
  portfolio cannot report completion while a target is missing a disposition.

## When you don't need this

- One machine, one chat at a time, no batches: the process skills
  (shakacode/agent-workflows) work fine with `coordination_backend: n/a`.
- You've bought into a cloud agent platform for execution: it owns scheduling
  and liveness; this plane is redundant there (though it still covers the local
  sessions the platform can't see).
