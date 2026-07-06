# Batch Simulation Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the coordination protocol end-to-end with (a) deterministic scripted workers that run in CI with no LLM, and (b) two seeded GitHub test repos where real Codex and Claude sessions process issue batches and a scorecard verifies the outcome.

**Architecture:** Two layers over the same worker protocol. Layer 1 is a *protocol automaton* — a Ruby script that performs the exact worker sequence (claim → isolated clone/workdir → branch → fix → test → heartbeat phases → release) mechanically, so races and parity are CI-testable and deterministic. Layer 2 swaps the automaton for real `codex exec` / `claude -p` sessions against real GitHub repos seeded with known-fixable issues, and a verifier script scores the run (exactly one claim per issue, PR opened, CI state, no cross-lane collisions). The sim template project ships the full `.agents/` seam so the real agent-workflows skills resolve it like any consumer repo.

**Tech Stack:** Ruby 3.4 stdlib + minitest (automaton, verifier, tests), bash (runners), `gh` CLI (seeding, verification), local bare git repos for CI mode, GitHub Actions minitest CI inside the sim template.

## Global Constraints

- Layer 1 must run with **no network and no LLM**: local git bare repo as origin, `--state-root` LocalStore (and, once Phase 1 lands, the wrangler-dev HTTP backend) for coordination.
- All sim code lives under `sim/` in shakacode/agent-coordination. Nothing under `sim/` may be required by the CLI at runtime.
- Sim GitHub repos are `shakacode/agent-coord-sim-alpha` and `shakacode/agent-coord-sim-beta`, private. Their content is generated from `sim/template/` — never edited by hand.
- Every seeded issue is independently fixable, touches exactly one `lib/task_*.rb` file, and has a deterministic acceptance test.
- The exit-code contract (0/1/2/3) and `schema_version: 1` are unchanged — this plan adds no CLI features.
- `bundle exec rubocop` green before every commit; all files end with a newline.
- Steps marked **[OPERATOR]** need Justin (repo creation, running real Codex/Claude sessions).

---

### Task 1: Sim template project

**Files:**
- Create: `sim/template/lib/task_one.rb`, `sim/template/lib/task_two.rb`, `sim/template/lib/task_three.rb`
- Create: `sim/template/test/task_one_test.rb`, `sim/template/test/task_two_test.rb`, `sim/template/test/task_three_test.rb`
- Create: `sim/template/.agents/agent-workflow.yml`, `sim/template/.agents/bin/validate`, `sim/template/.agents/bin/test`, `sim/template/.agents/bin/ci`, `sim/template/.agents/bin/README.md`
- Create: `sim/template/AGENTS.md`, `sim/template/README.md`, `sim/template/Rakefile`
- Create: `sim/template/.github/workflows/ci.yml`
- Create: `sim/issues.json`

**Interfaces:**
- Produces: a complete consumer-repo tree with three deliberately buggy functions, three tests that FAIL until fixed, and the seam files real skills resolve. `sim/issues.json` is the single source of truth for issue seeding and verification.

- [x] **Step 1: Write the buggy libs and their tests**

Each task file has one bug; each test currently fails. `sim/template/lib/task_one.rb`:

```ruby
# frozen_string_literal: true

module TaskOne
  # BUG (sim issue 1): returns the sum including negatives; spec says
  # negatives are excluded from the total.
  def self.positive_sum(numbers)
    numbers.sum
  end
end
```

`sim/template/test/task_one_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_one"

class TaskOneTest < Minitest::Test
  def test_negatives_are_excluded
    assert_equal 6, TaskOne.positive_sum([1, 2, 3, -5])
  end

  def test_all_negative_is_zero
    assert_equal 0, TaskOne.positive_sum([-1, -2])
  end
end
```

`sim/template/lib/task_two.rb`:

```ruby
# frozen_string_literal: true

module TaskTwo
  # BUG (sim issue 2): downcases the whole string; spec says title-case
  # each word (first letter upper, rest lower).
  def self.title_case(text)
    text.downcase
  end
end
```

`sim/template/test/task_two_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_two"

class TaskTwoTest < Minitest::Test
  def test_title_cases_words
    assert_equal "Hello Wide World", TaskTwo.title_case("hello WIDE world")
  end
end
```

`sim/template/lib/task_three.rb`:

```ruby
# frozen_string_literal: true

module TaskThree
  # BUG (sim issue 3): off-by-one; spec says inclusive range count.
  def self.inclusive_count(first, last)
    last - first
  end
end
```

`sim/template/test/task_three_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_three"

class TaskThreeTest < Minitest::Test
  def test_counts_inclusively
    assert_equal 5, TaskThree.inclusive_count(3, 7)
  end
end
```

- [x] **Step 2: Write the seam and CI files**

`sim/template/Rakefile`:

```ruby
# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create(:test) { |t| t.test_globs = ["test/**/*_test.rb"] }
task default: :test
```

`sim/template/.agents/bin/test`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec rake test "$@"
```

`sim/template/.agents/bin/validate`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

base_ref="${AGENT_SIM_BASE_REF:-}"
if [ -z "$base_ref" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  git fetch --quiet origin "$GITHUB_BASE_REF" --depth=1
  base_ref="$(git rev-parse FETCH_HEAD)"
elif [ -z "$base_ref" ] && [ "$(git branch --show-current)" != "main" ]; then
  if git rev-parse --verify -q main >/dev/null; then
    base_ref="main"
  elif git rev-parse --verify -q origin/main >/dev/null; then
    base_ref="origin/main"
  fi
fi

if [ -n "$base_ref" ]; then
  changed="$(git diff --name-only "$base_ref")"
  changed_count="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
  tests="$(printf '%s\n' "$changed" |
    sed -n 's#^lib/\(task_.*\)\.rb$#test/\1_test.rb#p' |
    sort -u)"
  test_count="$(printf '%s\n' "$tests" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$changed_count" -gt 0 ]; then
    invalid="$(printf '%s\n' "$changed" |
      sed '/^$/d' |
      grep -Ev '^lib/task_[[:alnum:]_]+\.rb$' || true)"
    if [ -n "$invalid" ]; then
      printf 'Unexpected changed files for single-task validation:\n%s\n' "$invalid" >&2
      exit 1
    fi
    if [ "$test_count" -ne 1 ]; then
      printf 'Expected exactly one changed task file, found %s.\n' "$test_count" >&2
      exit 1
    fi
    for test_file in $tests; do
      if [ ! -f "$test_file" ]; then
        printf 'Expected matching test file for changed task: %s\n' "$test_file" >&2
        exit 1
      fi
      ruby "$test_file"
    done
    exit 0
  fi
fi

"$root/.agents/bin/test"
```

`sim/template/.agents/bin/ci`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

"$root/.agents/bin/validate"
```

(`chmod +x` all three scripts.) `sim/template/.agents/bin/README.md`:

```markdown
# Commands

| Script | Purpose |
| --- | --- |
| `ci` | GitHub Actions entrypoint. |
| `validate` | Sim-aware gate: exactly one changed task file runs its matching test; non-task diffs are rejected. |
| `test` | Run minitest suite. |
```

`sim/template/.agents/agent-workflow.yml`:

```yaml
base_branch: main
follow_up_prefix: "Follow-up:"
review_gate: none (sim repo)
approval_exempt: all (sim repo)
coordination_backend: agent-coord
changelog: n/a
benchmark_labels: n/a
merge_ledger: n/a
ci_parity_environment: n/a
hosted_ci_trigger: n/a
ci_change_detector: n/a
```

`sim/template/AGENTS.md`:

```markdown
# AGENTS.md

Simulation repo for shakacode/agent-coordination batch testing. Content is
generated from `sim/template/`; do not hand-edit outside a simulation run.

## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`ci`, `validate`, `test`); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
```

`sim/template/README.md`:

```markdown
# agent-coord sim repo

Generated fixture for batch simulation. See shakacode/agent-coordination
`docs/plans/2026-07-04-batch-simulation-harness.md`. Reseeding overwrites
history; never do real work here.
```

`sim/template/.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: ruby/setup-ruby@3fee6763234110473bd57dd4595c5199fce2c510 # v1.258.0
        with:
          ruby-version: "3.4"
      - run: gem install minitest rake
      - run: .agents/bin/ci
```

- [x] **Step 3: Write the issue manifest**

`sim/issues.json`:

```json
{
  "issues": [
    {
      "key": "task_one",
      "title": "positive_sum must exclude negative numbers",
      "file": "lib/task_one.rb",
      "test": "test/task_one_test.rb",
      "body": "TaskOne.positive_sum currently includes negatives in the total.\n\nSpec: negatives are excluded. positive_sum([1, 2, 3, -5]) must return 6; positive_sum([-1, -2]) must return 0.\n\nAcceptance: `ruby test/task_one_test.rb` passes. Change only lib/task_one.rb.\nDone when: PR opened referencing this issue and CI is green."
    },
    {
      "key": "task_two",
      "title": "title_case must capitalize each word",
      "file": "lib/task_two.rb",
      "test": "test/task_two_test.rb",
      "body": "TaskTwo.title_case currently downcases everything.\n\nSpec: title-case each whitespace-separated word. title_case(\"hello WIDE world\") must return \"Hello Wide World\".\n\nAcceptance: `ruby test/task_two_test.rb` passes. Change only lib/task_two.rb.\nDone when: PR opened referencing this issue and CI is green."
    },
    {
      "key": "task_three",
      "title": "inclusive_count is off by one",
      "file": "lib/task_three.rb",
      "test": "test/task_three_test.rb",
      "body": "TaskThree.inclusive_count(3, 7) returns 4; the range is inclusive so it must return 5.\n\nAcceptance: `ruby test/task_three_test.rb` passes. Change only lib/task_three.rb.\nDone when: PR opened referencing this issue and CI is green."
    }
  ]
}
```

- [x] **Step 4: Verify the template is self-consistently broken**

```bash
cd sim/template && rake test; echo "exit=$?"
```

Expected: 4 failures (Task One has two assertions; Tasks Two and Three have one each), non-zero exit — the bugs are real and the tests catch them.

- [x] **Step 5: Commit**

```bash
cd ../.. && bundle exec rubocop && git add sim && git commit -m "Add sim template project with three seeded bugs and seam files"
```

---

### Task 2: Seeding script

**Files:**
- Create: `sim/bin/seed`

**Interfaces:**
- Consumes: `sim/template/`, `sim/issues.json`.
- Produces: `sim/bin/seed <owner/repo> [--reset]` — force-pushes template content to `main` and (re)creates one labeled issue per manifest entry. Idempotent; `--reset` also closes old sim issues and deletes non-main branches.

- [x] **Step 1: Write it**

`sim/bin/seed`:

```bash
#!/usr/bin/env bash
# Usage: sim/bin/seed <owner/repo> [--reset]
set -euo pipefail
REPO="${1:?usage: seed <owner/repo> [--reset]}"
RESET="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
ISSUE_PAIRS="$(mktemp)"
cleanup() {
  rm -R -f "$WORK"
  rm -f "$ISSUE_PAIRS"
}
trap cleanup EXIT

case "$REPO" in
  shakacode/agent-coord-sim-alpha | shakacode/agent-coord-sim-beta) ;;
  *)
    echo "refusing to overwrite non-simulation repo: $REPO" >&2
    echo "allowed repos: shakacode/agent-coord-sim-alpha, shakacode/agent-coord-sim-beta" >&2
    exit 1
    ;;
esac

python3 - "$HERE/issues.json" > "$ISSUE_PAIRS" <<'PY'
import json
import sys
from collections import Counter

with open(sys.argv[1], encoding="utf-8") as handle:
    issues = json.load(handle)["issues"]

titles = [issue["title"] for issue in issues]
duplicates = [title for title, count in Counter(titles).items() if count > 1]
if duplicates:
    sys.stderr.write(
        "duplicate issue title(s) in sim/issues.json: " + ", ".join(duplicates) + "\n"
    )
    raise SystemExit(1)

for issue in issues:
    sys.stdout.write(issue["title"] + "\0" + issue["body"] + "\0")
PY

cp -R "$HERE/template/." "$WORK/"
cd "$WORK"
git init -q -b main && git add -A
git commit -qm "Seed sim content $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git remote add origin "https://github.com/$REPO"
git push -q --force origin main

if [ "$RESET" = "--reset" ]; then
  gh issue list --repo "$REPO" --label sim-batch --state open --limit 1000 --json number \
    --jq '.[].number' | while read -r n; do
    gh issue close "$n" --repo "$REPO" --comment "Reseeded." || true
  done
  gh api --paginate "repos/$REPO/branches" --jq '.[].name' | { grep -v '^main$' || true; } | while read -r b; do
    gh api -X DELETE "repos/$REPO/git/refs/heads/$b" || true
  done
fi

gh label create sim-batch --repo "$REPO" --color 5319e7 \
  --description "Seeded simulation issue" 2>/dev/null || true

existing_titles="$WORK/existing_titles"
gh issue list --repo "$REPO" --label sim-batch --state open --limit 1000 --json title \
  --jq '.[].title' > "$existing_titles"

count=0
created=0
skipped=0

while IFS= read -r -d '' TITLE && IFS= read -r -d '' BODY; do
  count=$((count + 1))
  if grep -Fxq -- "$TITLE" "$existing_titles"; then
    skipped=$((skipped + 1))
    continue
  fi
  gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY" --label sim-batch
  created=$((created + 1))
done < "$ISSUE_PAIRS"
echo "SEEDED $REPO with $count issues ($created created, $skipped skipped)"
```

```bash
chmod +x sim/bin/seed
```

- [ ] **Step 2: [OPERATOR] Create both sim repos and seed alpha**

```bash
gh repo create shakacode/agent-coord-sim-alpha --private --description "Batch simulation fixture A (generated; see agent-coordination sim/)"
gh repo create shakacode/agent-coord-sim-beta  --private --description "Batch simulation fixture B (generated; see agent-coordination sim/)"
sim/bin/seed shakacode/agent-coord-sim-alpha
```

Expected: `SEEDED shakacode/agent-coord-sim-alpha with 3 issues (3 created, 0 skipped)`, and the repo shows red CI on main (the seeded bugs) with 3 open `sim-batch` issues.

- [x] **Step 3: Commit**

```bash
bundle exec rubocop && git add sim/bin/seed && git commit -m "Add sim repo seeding script"
```

---

### Task 3: Scripted worker (protocol automaton)

**Files:**
- Create: `sim/bin/scripted-worker`
- Test: `sim/test/scripted_worker_test.rb`

**Interfaces:**
- Consumes: the `agent-coord` CLI (any backend via env), a git remote (local bare repo in CI mode), `sim/issues.json` keys.
- Produces: `sim/bin/scripted-worker --agent-id ID --repo-slug OWNER/REPO --clone-url URL --issue-key task_one --workdir DIR` which performs, in order: validate the issue key, `claim` (hard-stops on exit 3 printing `WORKER_REFUSED`), isolated `git clone` in `--workdir`, branch `sim/<issue-key>-<agent-id>`, applies the canonical fix, runs the acceptance test, commits, pushes, heartbeats at each phase (`claimed`, `implementing`, `validating`, `pushing`, `done`; `failed` on post-claim failure), `release`, prints `WORKER_DONE <branch>`. Exit 0 on done, 3 on refused, 2 otherwise.

- [x] **Step 1: Write the failing test**

`sim/test/scripted_worker_test.rb`:

```ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__) unless defined?(SIM_ROOT)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker") unless defined?(WORKER)

class ScriptedWorkerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @state = File.join(@dir, "state")
    Dir.mkdir(@state)
    @origin = File.join(@dir, "origin.git")
    system("git", "init", "-q", "--bare", @origin, exception: true)
    seed = File.join(@dir, "seed")
    FileUtils.cp_r(File.join(SIM_ROOT, "template", "."), seed)
    Dir.chdir(seed) do
      system("git init -q -b main && " \
             "git config user.name 'agent-coord sim test' && " \
             "git config user.email 'agent-coord-sim@example.invalid' && " \
             "git add -A && git commit -qm seed && " \
             "git remote add origin #{@origin} && git push -q origin main", exception: true)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_worker(agent_id, issue_key: "task_one", clone_url: @origin)
    env = { "AGENT_COORD_STATE_ROOT" => @state }
    Open3.capture3(
      env, WORKER,
      "--agent-id", agent_id, "--repo-slug", "sim/local",
      "--clone-url", clone_url, "--issue-key", issue_key,
      "--workdir", File.join(@dir, "work-#{agent_id}")
    )
  end

  def test_worker_completes_and_records_protocol
    stdout, stderr, status = run_worker("host:worker")
    assert_equal 0, status.exitstatus, "worker failed: #{stderr}"
    assert_includes stdout, "WORKER_DONE"

    claim = JSON.parse(File.read(File.join(@state, "claims", "sim", "local", "task_one.json")))
    assert_equal "released", claim.fetch("status")
    heartbeat = JSON.parse(File.read(File.join(@state, "heartbeats", "host:worker.json")))
    assert_equal "done", heartbeat.fetch("status")

    branches = `git --git-dir=#{@origin} branch --list`.lines.map(&:strip)
    assert_includes branches, "sim/task_one-host-worker"
  end

  def test_second_worker_is_refused_while_first_holds_claim
    env = { "AGENT_COORD_STATE_ROOT" => @state }
    system(
      env, File.expand_path("../../bin/agent-coord", __dir__),
      "claim", "--agent-id", "holder", "--repo", "sim/local",
      "--target", "task_one", exception: true, out: File::NULL
    )
    system(env, File.expand_path("../../bin/agent-coord", __dir__),
           "heartbeat", "--agent-id", "holder", exception: true, out: File::NULL)

    stdout, _stderr, status = run_worker("w2")
    assert_equal 3, status.exitstatus
    assert_includes stdout, "WORKER_REFUSED"
  end

  def test_unknown_issue_key_fails_before_claim
    stdout, _stderr, status = run_worker("w3", issue_key: "task_four")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "unknown issue key: task_four"
    refute File.exist?(File.join(@state, "claims", "sim", "local", "task_four.json"))
  end

  def test_invalid_branch_agent_id_fails_before_claim
    stdout, _stderr, status = run_worker("worker.lock")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "invalid worker branch: sim/task_one-worker.lock"
    refute File.exist?(File.join(@state, "claims", "sim", "local", "task_one.json"))
  end

  def test_failure_after_claim_releases_claim
    missing_origin = File.join(@dir, "missing.git")
    _stdout, _stderr, status = run_worker("w4", clone_url: missing_origin)
    assert_equal 2, status.exitstatus

    claim = JSON.parse(File.read(File.join(@state, "claims", "sim", "local", "task_one.json")))
    assert_equal "released", claim.fetch("status")
    heartbeat = JSON.parse(File.read(File.join(@state, "heartbeats", "w4.json")))
    assert_equal "failed", heartbeat.fetch("status")
  end
end
```

- [x] **Step 2: Run to verify failure**

Run: `bundle exec ruby sim/test/scripted_worker_test.rb`
Expected: FAIL — `sim/bin/scripted-worker` does not exist.

- [x] **Step 3: Implement the automaton**

`sim/bin/scripted-worker`:

```bash
#!/usr/bin/env bash
set -euo pipefail

AGENT_ID=""
REPO_SLUG=""
CLONE_URL=""
ISSUE_KEY=""
WORKDIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --repo-slug) REPO_SLUG="$2"; shift 2 ;;
    --clone-url) CLONE_URL="$2"; shift 2 ;;
    --issue-key) ISSUE_KEY="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

[ -n "$AGENT_ID" ] && [ -n "$REPO_SLUG" ] && [ -n "$CLONE_URL" ] &&
  [ -n "$ISSUE_KEY" ] && [ -n "$WORKDIR" ] || { echo "missing args"; exit 2; }

CLI="$(cd "$(dirname "$0")/../.." && pwd)/bin/agent-coord"
BRANCH_AGENT_ID="$(printf "%s" "$AGENT_ID" | LC_ALL=C tr -c "A-Za-z0-9._-" "-")"
BRANCH="sim/${ISSUE_KEY}-${BRANCH_AGENT_ID}"
CLAIM_ACQUIRED=0
WORK_PUSHED=0
DONE_RECORDED=0

apply_issue_fix() {
  local issue_key="$1"
  local mode="${2:-apply}"

  case "$issue_key" in
    task_one)
      [ "$mode" = "check" ] && return 0
      cat > lib/task_one.rb <<'RB'
# frozen_string_literal: true

module TaskOne
  def self.positive_sum(numbers)
    numbers.select(&:positive?).sum
  end
end
RB
      ;;
    task_two)
      [ "$mode" = "check" ] && return 0
      cat > lib/task_two.rb <<'RB'
# frozen_string_literal: true

module TaskTwo
  def self.title_case(text)
    text.split.map(&:capitalize).join(" ")
  end
end
RB
      ;;
    task_three)
      [ "$mode" = "check" ] && return 0
      cat > lib/task_three.rb <<'RB'
# frozen_string_literal: true

module TaskThree
  def self.inclusive_count(first, last)
    last - first + 1
  end
end
RB
      ;;
    *) return 1 ;;
  esac
}

if ! apply_issue_fix "$ISSUE_KEY" check; then
  echo "unknown issue key: $ISSUE_KEY"
  exit 2
fi

if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "invalid worker branch: $BRANCH"
  exit 2
fi

beat() {
  "$CLI" heartbeat --agent-id="$AGENT_ID" --repo="$REPO_SLUG" \
    --target="$ISSUE_KEY" --branch="$BRANCH" --status="$1"
}

release_claim() {
  "$CLI" release --agent-id="$AGENT_ID" --repo="$REPO_SLUG" --target="$ISSUE_KEY"
  local rc=$?
  [ "$rc" -eq 0 ] && CLAIM_ACQUIRED=0
  return "$rc"
}

cleanup_claim() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$CLAIM_ACQUIRED" -eq 1 ]; then
    if [ "$WORK_PUSHED" -eq 1 ]; then
      if [ "$DONE_RECORDED" -eq 0 ]; then
        if beat done >/dev/null; then
          DONE_RECORDED=1
        else
          echo "warning: failed to record done heartbeat for ${ISSUE_KEY}" >&2
          release_claim >/dev/null || echo "warning: failed to release claim for ${ISSUE_KEY}" >&2
          exit 2
        fi
      fi
      if release_claim >/dev/null; then
        echo "WORKER_DONE ${BRANCH}"
        exit 0
      fi
      echo "warning: failed to release claim for ${ISSUE_KEY}" >&2
    else
      beat failed >/dev/null || echo "warning: failed to record failed heartbeat for ${ISSUE_KEY}" >&2
      release_claim >/dev/null || echo "warning: failed to release claim for ${ISSUE_KEY}" >&2
    fi
    status=2
  fi
  exit "$status"
}
trap cleanup_claim EXIT

set +e
"$CLI" claim --agent-id="$AGENT_ID" --repo="$REPO_SLUG" --target="$ISSUE_KEY" --branch="$BRANCH"
CODE=$?
set -e
if [ "$CODE" -eq 3 ]; then echo "WORKER_REFUSED ${ISSUE_KEY}"; exit 3; fi
[ "$CODE" -eq 0 ] || exit 2
CLAIM_ACQUIRED=1
beat claimed

mkdir -p "$WORKDIR"
cd "$WORKDIR"
git clone -q --branch main --depth 1 --no-tags -- "$CLONE_URL" repo
cd repo
git config user.name "agent-coord sim worker"
git config user.email "agent-coord-sim@example.invalid"
git checkout -q -b "$BRANCH"
beat implementing

apply_issue_fix "$ISSUE_KEY"

beat validating
ruby "test/${ISSUE_KEY}_test.rb"

beat pushing
git add lib
git commit -qm "Fix ${ISSUE_KEY} (scripted sim worker ${AGENT_ID})"
git push -q origin "$BRANCH"
WORK_PUSHED=1

beat done
DONE_RECORDED=1
release_claim
echo "WORKER_DONE ${BRANCH}"
```

```bash
chmod +x sim/bin/scripted-worker
```

- [x] **Step 4: Run to verify pass**

Run: `bundle exec ruby sim/test/scripted_worker_test.rb`
Expected: `4 runs ... 0 failures, 0 errors`.

- [x] **Step 5: Lint and commit**

```bash
bundle exec rubocop && git add sim && git commit -m "Add scripted protocol-automaton worker with tests"
```

---

### Task 4: Race scenario — two automata, one target, one winner

**Files:**
- Create: `sim/test/race_test.rb`
- Modify: `.github/workflows/ci.yml` (add sim tests to the existing `test` job command list)

**Interfaces:**
- Consumes: Task 3's automaton.
- Produces: CI-enforced proof that concurrent scripted workers on the same target yield exactly one `WORKER_DONE` and one `WORKER_REFUSED` (or operational loser), and exactly one branch on origin.

- [x] **Step 1: Write the test**

`sim/test/race_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

SIM_ROOT = File.expand_path("..", __dir__) unless defined?(SIM_ROOT)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker") unless defined?(WORKER)

class RaceTest < Minitest::Test
  def test_concurrent_workers_one_winner
    Dir.mktmpdir do |dir|
      state = File.join(dir, "state").tap { |d| Dir.mkdir(d) }
      origin = File.join(dir, "origin.git")
      system("git", "init", "-q", "--bare", origin, exception: true)
      seed = File.join(dir, "seed")
      FileUtils.cp_r(File.join(SIM_ROOT, "template", "."), seed)
      Dir.chdir(seed) do
        system("git init -q -b main && git add -A && git commit -qm seed && " \
               "git remote add origin #{origin} && git push -q origin main", exception: true)
      end

      env = { "AGENT_COORD_STATE_ROOT" => state }
      results = Array.new(3)
      threads = results.each_index.map do |i|
        Thread.new do
          _, _, status = Open3.capture3(
            env, WORKER, "--agent-id", "racer#{i}", "--repo-slug", "sim/race",
            "--clone-url", origin, "--issue-key", "task_two",
            "--workdir", File.join(dir, "work#{i}")
          )
          results[i] = status.exitstatus
        end
      end
      threads.each(&:join)

      assert_equal 1, results.count(0), "exactly one winner expected, got #{results.inspect}"
      assert results.all? { |code| [0, 2, 3].include?(code) }, "unexpected exits: #{results.inspect}"
      branches = `git --git-dir=#{origin} branch --list`.lines.map(&:strip).grep(/^sim\//)
      assert_equal 1, branches.length, "exactly one sim branch expected, got #{branches.inspect}"
    end
  end
end
```

- [x] **Step 2: Run it**

Run: `bundle exec ruby sim/test/race_test.rb`
Expected: PASS (exactly one winner).

- [x] **Step 3: Add sim tests to CI**

In `.github/workflows/ci.yml`, in the existing `test` job, after the current test command add two run lines:

```yaml
      - run: bundle exec ruby sim/test/scripted_worker_test.rb
      - run: bundle exec ruby sim/test/race_test.rb
```

- [x] **Step 4: Lint, commit, push, watch CI**

```bash
bundle exec rubocop && git add -A && git commit -m "Add scripted-worker race test to CI"
```

---

### Task 5: Batch verifier scorecard

**Files:**
- Create: `sim/bin/verify-batch`
- Test: `sim/test/verify_batch_test.rb`

**Interfaces:**
- Consumes: coordination state (any backend via env) + `gh` for live-repo mode.
- Produces: `sim/bin/verify-batch --repo-slug OWNER/REPO [--live]` printing one line per manifest issue — `PASS <key> claim=released branch=<b> pr=<url|SKIPPED> ci=<state|SKIPPED>` or `FAIL <key> <reason>` — and a final `SCORE n/m`. Exit 0 only when n == m. Without `--live`, PR/CI columns are `SKIPPED` (CI mode); with `--live`, it queries `gh pr list --head <branch>` and the PR's checks.

- [ ] **Step 1: Write the failing test** (CI mode against LocalStore fixtures)

`sim/test/verify_batch_test.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class VerifyBatchTest < Minitest::Test
  VERIFY = File.expand_path("../bin/verify-batch", __dir__)

  def write(state, path, data)
    full = File.join(state, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, JSON.pretty_generate(data))
  end

  def released_claim(target)
    { "schema_version" => 1, "repo" => "sim/verify", "target" => target,
      "agent_id" => "w-#{target}", "branch" => "sim/#{target}-w",
      "status" => "released", "claimed_at" => "2026-07-04T00:00:00Z",
      "updated_at" => "2026-07-04T00:10:00Z", "expires_at" => "2026-07-04T00:10:00Z" }
  end

  def test_all_released_claims_score_full
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |t|
        write(state, "claims/sim/verify/#{t}.json", released_claim(t))
      end
      stdout, _, status = Open3.capture3(
        { "AGENT_COORD_STATE_ROOT" => state }, VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 0, status.exitstatus, stdout
      assert_includes stdout, "SCORE 3/3"
    end
  end

  def test_missing_claim_fails_that_row
    Dir.mktmpdir do |state|
      write(state, "claims/sim/verify/task_one.json", released_claim("task_one"))
      stdout, _, status = Open3.capture3(
        { "AGENT_COORD_STATE_ROOT" => state }, VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 1, status.exitstatus
      assert_includes stdout, "FAIL task_two"
      assert_includes stdout, "SCORE 1/3"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby sim/test/verify_batch_test.rb`
Expected: FAIL — verify-batch missing.

- [ ] **Step 3: Implement**

`sim/bin/verify-batch` (Ruby for JSON handling):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

args = ARGV.dup
repo_slug = nil
live = false
while (arg = args.shift)
  case arg
  when "--repo-slug" then repo_slug = args.shift
  when "--live" then live = true
  else abort "unknown arg: #{arg}"
  end
end
abort "usage: verify-batch --repo-slug OWNER/REPO [--live]" unless repo_slug

sim_root = File.expand_path("..", __dir__)
cli = File.join(sim_root, "..", "bin", "agent-coord")
manifest = JSON.parse(File.read(File.join(sim_root, "issues.json"))).fetch("issues")

stdout, stderr, status = Open3.capture3("ruby", cli, "status", "--json")
abort "agent-coord status failed: #{stderr}" unless status.success?
claims = JSON.parse(stdout).fetch("claims")

passes = 0
manifest.each do |issue|
  key = issue.fetch("key")
  claim = claims.find { |c| c["repo"] == repo_slug && c["target"] == key }
  unless claim
    puts "FAIL #{key} no claim recorded"
    next
  end
  unless claim["status"] == "released"
    puts "FAIL #{key} claim status=#{claim['status']} (expected released)"
    next
  end

  pr_col = "SKIPPED"
  ci_col = "SKIPPED"
  if live
    branch_out, = Open3.capture3(
      "gh", "pr", "list", "--repo", repo_slug, "--state", "all",
      "--search", "#{issue.fetch('title')} in:title", "--json", "url,headRefName,number"
    )
    pr = JSON.parse(branch_out).first
    if pr.nil?
      puts "FAIL #{key} no PR found"
      next
    end
    pr_col = pr.fetch("url")
    checks_out, = Open3.capture3(
      "gh", "pr", "checks", pr.fetch("number").to_s, "--repo", repo_slug,
      "--json", "bucket", "--jq", "[.[].bucket] | unique | join(\",\")"
    )
    ci_col = checks_out.strip.empty? ? "none" : checks_out.strip
    if ci_col.include?("fail")
      puts "FAIL #{key} CI failing (#{ci_col}) #{pr_col}"
      next
    end
  end

  passes += 1
  puts "PASS #{key} claim=released pr=#{pr_col} ci=#{ci_col}"
end

puts "SCORE #{passes}/#{manifest.length}"
exit(passes == manifest.length ? 0 : 1)
```

```bash
chmod +x sim/bin/verify-batch
```

- [ ] **Step 4: Run tests, lint, commit**

Run: `bundle exec ruby sim/test/verify_batch_test.rb`
Expected: PASS.

```bash
bundle exec rubocop && git add sim && git commit -m "Add batch verifier scorecard"
```

---

### Task 6: LLM batch runner + playbook (Layer 2)

**Files:**
- Create: `sim/bin/llm-worker`
- Create: `sim/prompts/worker-prompt.md`
- Create: `sim/PLAYBOOK.md`

**Interfaces:**
- Consumes: real sim repos (Task 2), real `codex` / `claude` CLIs on the operator machine, coordination backend via env.
- Produces: one command per lane that launches a real headless agent session on a seeded issue, and a written playbook for the three canonical scenarios.

- [ ] **Step 1: Write the worker prompt template**

`sim/prompts/worker-prompt.md`:

```markdown
You are a batch worker processing one issue in a simulation repo. Follow this
exact protocol; if any coordination command exits 3 (CLAIM_REFUSED), stop
immediately and report the holder — do not work the issue.

Repo: {{REPO}}   Issue: #{{ISSUE_NUMBER}}   Agent id: {{AGENT_ID}}   Batch: {{BATCH_ID}}

1. Claim before any code: run
   `agent-coord claim --agent-id {{AGENT_ID}} --repo {{REPO}} --target {{ISSUE_NUMBER}} --batch-id {{BATCH_ID}}`
   Exit 3 → stop and report. Then heartbeat status claimed.
2. Clone {{REPO}}, create branch `sim/issue-{{ISSUE_NUMBER}}-{{AGENT_ID}}`.
3. Read issue #{{ISSUE_NUMBER}}. Fix ONLY the file it names. Heartbeat status
   implementing.
4. Run `.agents/bin/validate`. It must pass. Heartbeat status validating.
5. Commit, push the branch, open a PR titled after the issue with
   "Fixes #{{ISSUE_NUMBER}}" in the body. Heartbeat status pushing --branch <branch>.
6. Heartbeat status done, then
   `agent-coord release --agent-id {{AGENT_ID}} --repo {{REPO}} --target {{ISSUE_NUMBER}}`.
7. Final message: issue number, branch, PR URL, one-line result.
```

- [ ] **Step 2: Write the launcher**

`sim/bin/llm-worker`:

```bash
#!/usr/bin/env bash
# Usage: sim/bin/llm-worker (codex|claude) <owner/repo> <issue-number> <batch-id>
set -euo pipefail
HOST="${1:?usage: llm-worker (codex|claude) <owner/repo> <issue> <batch-id>}"
REPO="${2:?}"; ISSUE="${3:?}"; BATCH="${4:?}"
AGENT_ID="sim-${HOST}-${ISSUE}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT=$(sed -e "s|{{REPO}}|$REPO|g" -e "s|{{ISSUE_NUMBER}}|$ISSUE|g" \
             -e "s|{{AGENT_ID}}|$AGENT_ID|g" -e "s|{{BATCH_ID}}|$BATCH|g" \
             "$HERE/prompts/worker-prompt.md")
WORK="$(mktemp -d)"
cd "$WORK"
case "$HOST" in
  codex)  codex exec --full-auto "$PROMPT" ;;
  claude) claude -p "$PROMPT" --permission-mode acceptEdits \
            --allowedTools "Bash,Read,Edit,Write,Glob,Grep" ;;
  *) echo "host must be codex or claude"; exit 1 ;;
esac
echo "LLM_WORKER_EXIT host=$HOST issue=$ISSUE workdir=$WORK"
```

```bash
chmod +x sim/bin/llm-worker
```

- [ ] **Step 3: Write the playbook**

`sim/PLAYBOOK.md`:

```markdown
# Simulation Playbook

Prereqs: backend env set (`AGENT_COORD_API_URL`+token, or a shared
`AGENT_COORD_BACKEND` state repo), `gh` authed, `codex` and/or `claude` CLIs
installed, sim repos seeded (`sim/bin/seed <repo> --reset`).

## Scenario A — split batch, one host per repo
1. `sim/bin/seed shakacode/agent-coord-sim-alpha --reset`
2. For each seeded issue N in alpha: `sim/bin/llm-worker codex shakacode/agent-coord-sim-alpha N sim-$(date +%s)`
3. Same on beta with `claude`.
4. Score: `sim/bin/verify-batch --repo-slug shakacode/agent-coord-sim-alpha --live` (and beta).
   Expect `SCORE 3/3` on both.

## Scenario B — contention: both hosts, same issue
1. Reseed alpha.
2. In two terminals, launch simultaneously:
   `sim/bin/llm-worker codex  shakacode/agent-coord-sim-alpha 1 race-test`
   `sim/bin/llm-worker claude shakacode/agent-coord-sim-alpha 1 race-test`
3. Expect exactly one PR; the loser's transcript reports CLAIM_REFUSED with
   the holder. If both produced PRs, the claim gate failed — file it.

## Scenario C — lost session recovery
1. Launch a worker on issue 2; kill the process after the `implementing`
   heartbeat (watch `agent-coord status --json`).
2. Wait for heartbeat death (4 x TTL), then relaunch with the other host.
3. Expect takeover, one final PR, and `verify-batch --live` passing for that
   issue. This is the "work can get lost" use case exercised end to end.

Teardown: `sim/bin/seed <repo> --reset` after every scenario; sim repos never
hold real work.
```

- [ ] **Step 4: [OPERATOR] Dry-run Scenario A on alpha with one issue and one host**

Expected: PR opened referencing the issue, `verify-batch --live` shows `PASS` for that key.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop && git add sim && git commit -m "Add LLM batch runner, worker prompt, and simulation playbook"
```
