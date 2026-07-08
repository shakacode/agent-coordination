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
release-with-handoff on machine A (records branch, PR, and next steps as a
resume note), then claim on machine B — or **supersede** when machine A's
session is dead but its lease isn't. It's the worktree insight again, applied
across machines: make the ownership boundary explicit and the switch becomes
routine.

### Use case 3b: Plan windows — cap-aware work, cross-host failover

Both vendors meter subscriptions (5-hour windows, weekly caps). When one app
hits its cap, every lane it hosts stalls at once — and without limit tracking
that looks identical to several broken workers. The coordination plane records
cap state per machine+app pair, shows the reset countdown, and offers the move
that actually helps: **hand the work item to the other vendor** — release with
a handoff note (branch, PR, phase, next steps), re-claim from the other app,
keep going on the same branch and PR. Claims, branches, and PRs are
host-agnostic, so switching a work item from Codex to Claude Code mid-PR (or
back) is a routine handoff, not a restart.

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

## When you don't need this

- One machine, one chat at a time, no batches: the process skills
  (shakacode/agent-workflows) work fine with `coordination_backend: n/a`.
- You've bought into a cloud agent platform for execution: it owns scheduling
  and liveness; this plane is redundant there (though it still covers the local
  sessions the platform can't see).
