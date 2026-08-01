# /test-plan

Walk a codebase, enumerate every testable surface, and emit a structured,
code-grounded corpus of test cases — a generator, not a renderer. The output is
DATA: a YAML (or JSON) corpus plus a markdown index, sized for a whole repo
(~6-10 surface areas, ~100 cases) rather than for one change set. Every case
carries a stable id, copy-pasteable prereqs / steps / expected / gotchas, a
`safe` or `live` risk tag, shell-aware commands, and at least one `file:line`
citation to the code that establishes it. An **executor** consumes the corpus:
`/smoke-form` renders the human-visual subset into an interactive HTML pass for
a person, while an agent or the test suite runs everything else.

Reach for it before a release gate, when inheriting a codebase nobody has
tested, or whenever "what would we even test here?" needs an answer with
citations. `/smoke-form` is scoped to a *change set* by construction and stops
at a few dozen items; this is the codebase-wide sweep upstream of it, and it
hands `/smoke-form` its items instead of competing with it.

## Arguments

- `$ARGUMENTS` - Optional configuration. Space-separated tokens:
  - First positional: scope (path, directory, or quoted area like
    `"the billing path"`). Defaults to the whole repo.
  - `surveyors=N` — parallel discovery agents (default: 4, clamp 2-6).
  - `mode=safe|live` — the safe-mode gate (default: `safe`). See section 6.
  - `shell=auto|bash|git-bash|zsh|powershell` — target shell for emitted
    commands (default: `auto` — detect, and ask if detection is ambiguous).
  - `format=yaml|json|both` — corpus serialization (default: `yaml`).
  - `areas=a,b,c` — restrict discovery to named areas from the taxonomy in
    section 3.
  - `output=DIR` — output directory. Pass `output=-` to print and write nothing.

Examples:
```
/test-plan
/test-plan packages/server surveyors=5
/test-plan "the money path" mode=live shell=powershell
/test-plan areas=setup,api,data format=both
/test-plan . surveyors=6 output=-
```

## Output location (resolution order)

1. `output=DIR` if given (`-` means print only).
2. {{CUSTOMIZE: Default corpus directory — e.g. `docs/test-plan/` or a QA folder this repo already uses}}

Filenames: `<slug>-<YYYYMMDD>.cases.yaml` (the corpus) and
`<slug>-<YYYYMMDD>.md` (the index). Never overwrite — append `-2`, `-3` on
collision, because a corpus someone has already recorded results against is a
record, not a draft.

## Instructions

### 1. Parse arguments and confirm the scope

```
SCOPE      = first positional (path, dir, or quoted area) — default: repo root
SURVEYORS  = extract from surveyors=N (default: 4, clamp 2-6)
MODE       = extract from mode=X (default: safe)
SHELL      = extract from shell=X (default: auto)
FORMAT     = extract from format=X (default: yaml)
AREAS      = extract from areas=a,b,c (default: whatever discovery finds)
OUTPUT_DIR = extract from output=DIR (default: the resolved directory above)
```

State the scope and the area list back to the user before the fan-out — a
codebase sweep is expensive and a wrong scope wastes all of it.

### 2. Resolve the target shell — before writing a single command

Every case in the corpus contains commands, so the shell decision is upstream of
all of them. Resolve it first and record it in the corpus header.

```bash
uname -s 2>/dev/null      # Darwin · Linux · MINGW64_NT-* / MSYS_NT-* = Git Bash
echo "${SHELL:-}"; echo "${OSTYPE:-}"
```

- **Emit commands for one named shell.** Default to Git Bash on Windows,
  LABEL any PowerShell-only command as PowerShell-only, and give both forms
  whenever a case sets an environment variable inline. A corpus is valid only
  for the shell it was generated for; a bash-shaped command handed to a
  PowerShell operator fails in a way that reads like a product bug.
- Inline-env prefixes are the classic trap — `VAR=value cmd` is bash-only:

  ```bash
  # bash / Git Bash
  SESSION_SECRET=dev-only node scripts/run-live.mjs --check
  ```
  ```powershell
  # PowerShell ONLY
  $env:SESSION_SECRET='dev-only'; node scripts/run-live.mjs --check
  ```

- Avoid GNU-only invocations unless the resolved shell is confirmed to have
  them: `stat -c %Y f` (use `date -r f` on BSD/macOS, or `node -e` /
  `python3 -c` for a portable mtime), `date -d`, `sed -i` with no backup
  suffix, `readlink -f`. When a portable form exists, prefer it over a labeled
  pair — one command everyone can run beats two nobody reads.
- If detection is ambiguous (a remote operator, a CI container, a Windows box
  with both shells), **ask** which shell the cases will be run in rather than
  guessing. One question now is cheaper than a corpus of unrunnable commands.

{{CUSTOMIZE: The shell(s) this repo's maintainers and testers actually run — e.g. "macOS zsh for devs, Git Bash for the Windows tester" — so `auto` has a documented fallback}}

### 3. Enumerate the surfaces (discovery fan-out)

This is the step `/smoke-form` has no equivalent of, and the reason this skill
exists. Fan out over the scope with `SURVEYORS` parallel agents, each assigned
whole areas from the taxonomy below. Surveyors **enumerate and cite**; they do
not yet write cases.

| Area | What lives here | Where to look |
|---|---|---|
| `setup` | bootstrap, env vars, config precedence, secrets, first-run | `.env.example`, config loaders, every `process.env.` / `os.environ` / `ENV[` read, the README's setup section |
| `build` | build, package, codegen, migrations, release/publish | CI workflows, `package.json` scripts, Makefile, Dockerfile, release scripts |
| `cli` | commands, subcommands, flags, exit codes, stdin/stdout contracts | argument parsers, `bin` entries, `main()` |
| `api` | HTTP/RPC routes, status codes, auth middleware, payload validation | router registrations, handler modules, OpenAPI/schema files |
| `data` | persistence, migrations, queues, schedulers, pipelines | schema/migration dirs, ORM models, job consumers, cron definitions |
| `money` | payments, billing, credits, ledgers, scoring/economy | anything touching a price, balance, currency, quota or ledger symbol |
| `ui` | screens, components, navigation, real-device behavior | view/component tree, route table, platform-specific code |
| `external` | third-party APIs, webhooks, OAuth, email/push/SMS | SDK clients, webhook handlers, outbound HTTP calls |
{{CUSTOMIZE: Extra area rows this repo genuinely has — copy ONLY areas the customization notes explicitly name, in the same 3-column pipe format (Area | What lives here | Where to look). If the notes name none, REMOVE THIS MARKER LINE ENTIRELY so the table ends cleanly. Do NOT invent areas from the tech stack.}}

**Surveyor prompt template:**

```
You are surveying a codebase to enumerate its TESTABLE SURFACES. You are not
writing tests and not judging quality — you are producing an inventory that a
later step turns into test cases.

## Scope
{SCOPE}

## Your areas
{AREAS FOR THIS SURVEYOR, with the "where to look" column}

## Output — one row per surface, nothing else

- surface: <one line: the thing that can be exercised>
  area: <area slug>
  grounding: <path/file.ext:LINE — the line that establishes it>
  anchor: "<a short quoted snippet from that line>"
  entry: <how it is reached: a command, a route, an env var, a screen>
  observable: <what a run of it produces that could be checked>
  side_effects: <writes/sends/charges anything real? name it, or "none seen">

## Rules
- READ the files. A grep hit is a candidate, not a surface — open it and confirm
  the line says what the match implied.
- Cite `file:line` on every row. A row without one is dropped.
- If you cannot determine a surface's side effects from the code, say
  "unknown" — that routes it to the cautious side later.
- List what you could SEE but could not CITE under a final `ungrounded:`
  heading. That list is a real result, not a failure.
```

Run surveyors in parallel; batch if `SURVEYORS > 4`. Merge their inventories and
dedup by `grounding` (same file within ±3 lines and an overlapping surface
description = one surface).

### 4. Ground every case in real code — the never-fabricate rule

The corpus is only worth what its citations are worth. An executor cannot tell a
real command from a plausible one until it fails.

- **Never fabricate.** If you cannot point at the code that establishes a
  command, route, port, env var or flag, OMIT the case:
  an invented command is worse than a missing one, because someone runs it,
  it fails, and the failure gets blamed on the product instead of on the plan.
- Every case MUST carry at least one `file:line` grounding entry, and every
  command, route, port, flag and env var it names must trace back to one of
  those entries. No grounding, no case.
- Store a short **anchor snippet** beside each citation. Line numbers drift with
  the next commit; the quoted text is what lets a reader re-find the code.
- Record the repo commit in the corpus header so every citation resolves against
  a known tree.
- **Omissions are output, not failure.** Keep the `ungrounded` list from step 3
  in the corpus and report it: surfaces you could see but could not cite are the
  honest edge of the sweep, and they are where the next pass starts.
- **Never embed a real secret, token, key or account id in a case.** Reference
  the env var or credential by name (cited), never the value, and let the
  operator supply it — a corpus gets committed, pasted into issues, and read by
  agents.

### 5. The case schema (the data contract)

One case = one observable check. This shape is what executors consume; keep the
field names exactly as written.

```yaml
- id: api-007                      # <area>-NNN — stable, unique, and the key results are recorded against
  title: "Unauthenticated POST /v1/jobs is rejected with 401"
  area: api
  executor: agent                  # human-visual | agent | suite — section 7
  risk: safe                       # safe | live — section 6
  shell: bash                      # bash | git-bash | zsh | powershell | both — section 2
  prereqs:
    - "dev server on 127.0.0.1:8787 — `npm run dev`"
  steps:
    - "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/v1/jobs"
  expected: "Prints 401."
  gotchas: "With NODE_ENV=development the auth middleware seeds a bypass token, and this returns 202 instead. Unset DEV_BYPASS first."
  grounding:
    - file: "src/routes/jobs.ts:14"
      anchor: "router.post('/v1/jobs', requireAuth, createJob)"
    - file: "src/middleware/auth.ts:22"
      anchor: "res.status(401).json({ error: 'unauthorized' })"
  cleanup: "none — nothing written"
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `<area>-NNN`. **Stable across regenerations** — when re-running, keep an existing id whose title still matches, so results already recorded against it stay meaningful. |
| `title` | yes | One line, names the observable, not the implementation. |
| `area` | yes | A slug from the section-3 taxonomy. |
| `executor` | yes | See section 7. |
| `risk` | yes | See section 6. |
| `shell` | yes when `steps` contain commands | `both` means the case carries a labeled pair. |
| `prereqs` | yes when setup is needed | Services, fixtures, devices, env vars — each with the command that satisfies it. |
| `steps` | yes | Numbered, exact, copy-pasteable. An operator who has never read the code must be able to run them verbatim. |
| `expected` | yes | The pass condition, stated plainly. **Every clause must trace to a step** — never assert the result of an action nobody was told to perform. |
| `gotchas` | optional | The trap that makes a correct implementation look broken (or a broken one look fine): a cache, a seeded bypass, a 30-second debounce, a platform difference. Cite it like anything else. Empty is fine; invented is not. |
| `grounding` | yes, ≥ 1 | `file` + `anchor` pairs. See section 4. |
| `cleanup` | yes for `live`, else optional | What to undo. `safe` cases usually say "none". |
| `gate` | yes for `live` | See section 6. |
| `blast_radius` | yes for `live` | See section 6. |

**One observable check per case.** "Starts without crashing" + "writes the
config" + "is idempotent on a second run" is three cases. If `expected` has
independent AND-clauses testing unrelated behavior, split it.

### 6. Risk tagging: `safe` vs `live`, and the safe-mode gate

A case that reads is not the same as a case that sends, charges or writes, and
the corpus must say which is which *per case* — a global "be careful" note is
not a tag and cannot be enforced.

**`safe`** requires ALL of:
1. loopback / localhost / a local fixture only — no shared or remote host;
2. no real credentials — placeholder or test-mode keys only;
3. no write to shared, staging or production state;
4. no outbound message, email, push, webhook, SMS or payment;
5. idempotent — running it twice leaves nothing behind.

**`live`** is anything that fails one of those five.

- **Tag every case `safe` or `live`; when the code you read does not prove all
  five conditions hold, the default on doubt is `live`.** "Probably safe" is
  `live`. Mis-tagging in this direction costs an operator one confirmation
  prompt; mis-tagging the other way costs a real message to a real customer.
- Every `live` case additionally carries:
  - `gate:` the exact env var, flag or credential that must be present for it to
    run, cited like everything else (`STRIPE_LIVE_KEY — src/pay/client.ts:31`);
  - `blast_radius:` one line naming what real thing changes if it runs — money
    moved, message sent, row written, quota consumed.
- **The safe-mode gate.** The corpus header records `mode:`. Under `mode=safe`
  (the default) an executor must refuse to run any `live` case unless the
  operator satisfies its `gate` explicitly; state that contract in the header so
  the refusal is machine-checkable rather than a matter of taste. `mode=live`
  only widens what an executor *may* run — it never removes a tag and never
  edits a `blast_radius`.
- Tagging is not filtering: `live` cases stay in the corpus. A plan that hides
  its dangerous cases is a plan that never tests the money path.

{{CUSTOMIZE: This repo's real-side-effect gate — the env var / credential / flag that separates test-mode from live (e.g. `STRIPE_KEY` prefix, `SEND_REAL_EMAILS`, a staging DSN), plus anything that is NEVER safe to exercise here}}

### 7. Routing: which executor gets which case — and the `/smoke-form` boundary

`/smoke-form` is deliberately narrow, and that narrowness is what makes it good.
Its own rule (`generic/smoke-form.md`) reads: **"LIVE / VISUAL ONLY — never put
a purely back-end check in front of a human,"** and it instructs that a case
shaped "run `X`, confirm the output is `Y`" be moved to the test suite and left
off the checklist entirely.

- **Never route a purely back-end case to a human.** A case earns
  `executor: human-visual` only when its `expected` names something a person at
  the running app can see or do; a case whose whole content is a command and its
  output goes to `agent` or `suite`, and never onto a `/smoke-form` checklist.
- This skill does not relax that rule, does not argue with it, and does not work
  around it by rendering its own document. The rule is why the corpus has three
  executors instead of one.

| Case shape | Executor |
|---|---|
| Layout, rendering, animation, spacing, truncation, theming | `human-visual` |
| Real-device input: touch, camera, permissions, background/resume | `human-visual` |
| A screen state a person must judge ("does this chart look wrong?") | `human-visual` |
| CLI output, exit codes, HTTP status codes, response shapes | `agent` |
| Setup/env sequences, migrations, service startup | `agent` |
| Anything needing a live third party, real payment or real recipient | `agent`, tagged `live` |
| Return values, numeric/statistical correctness, sort orders, parser output | `suite` |

- **`suite` is a backlog, not a plan.** A `suite` case means "this belongs in an
  automated test that does not exist yet." Emit it with full grounding so
  someone can write it, and hand the list to `/create-issue` — one grouped issue
  per area, never one per case.
- Routing is not a quality ranking. An `agent` case is not a lesser case; it is
  a case whose executor is not a pair of eyes.
- Do not emit a case that green automated tests already cover, unless it has a
  visual or real-device component the automation cannot observe.

{{CUSTOMIZE: What this repo's automated suite already covers (and the command that runs it) — so `suite` cases are genuinely missing tests rather than duplicates}}

### 8. Scale and coverage discipline

The target is **coverage of surfaces**, not a case count. A hundred cases spread
over three areas is padding; sixty across every real surface is a sweep.

- Rough shape for a whole repo: 6-10 areas × 6-15 cases. Treat it as a sanity
  check on breadth, never as a quota to fill.
- An area with fewer than three grounded cases is a **finding** — say so in the
  report. Either the surface is genuinely thin or the sweep did not reach it.
- Two cases that always fail together on the same defect are one case.
- Drop, don't pad. Cases exist to be executed; a vague one wastes a real run.
- **The human-visual stream inherits `/smoke-form`'s ceiling** — it groups items
  into 4-8 sections of 3-10 each. If the `human-visual` subset is bigger than
  that, split it into more than one form by surface. Never hand `/smoke-form` a
  hundred-item checklist; that is exactly the shape its scale rule rejects.

### 9. Emit the corpus

**This skill emits data, not a document. Never render the corpus as HTML —
`/smoke-form` owns the rendering, and a second renderer forks a checklist format
that already works.** Write the corpus, then hand it over.

```
${OUTPUT_DIR}/<slug>-<YYYYMMDD>.cases.yaml   # the load-bearing artifact
${OUTPUT_DIR}/<slug>-<YYYYMMDD>.md           # human-readable index
```

`format=json` writes `.cases.json` with identical field names; `format=both`
writes both. Corpus header:

```yaml
plan:
  scope: "packages/server"
  generated: 2026-07-24
  repo_commit: 4f2a9c1          # every file:line citation resolves against this tree
  shell: bash
  mode: safe
  gate_contract: "executors must refuse `risk: live` cases unless the case's `gate` is explicitly satisfied"
  areas: [setup, api, data, money, external]
  counts:
    total: 104
    safe: 88
    live: 16
    human_visual: 22
    agent: 55
    suite: 27
  ungrounded:
    - "the websocket reconnect path — reached only from a vendored bundle, no readable source"
cases:
  - id: ...
```

The markdown index is a reader's view of the same data: one table per area
(`id · title · executor · risk · grounding`), the `live` cases listed together
with their blast radius, and the `ungrounded` list at the end.

**Validate your own output before reporting it.** Mechanically confirm: ids
unique and well-formed; every case has ≥ 1 grounding, a `risk` and an
`executor`; every `live` case has `gate` + `blast_radius` + `cleanup`; no
`human-visual` case whose `expected` lacks an on-screen observable; no literal
secret anywhere in the file; every command consistent with the header's `shell`
or explicitly labeled. Fix or drop what fails — do not report a corpus you have
not checked.

### 10. Hand off and report

- **`human-visual` → `/smoke-form`.** Invoke it with the corpus path and
  instruct it to render the supplied cases **verbatim** rather than re-deriving
  items from a change set; the `grounding` citations fill its Source field. If
  the subset exceeds its ceiling, hand it one form per surface.
- **`agent` → an agent runner or a live session.** Each case is already a
  self-contained command block with prereqs, expected and gotchas.
- **`suite` → `/create-issue`**, grouped by area, each issue carrying the cases'
  grounding so whoever writes the tests starts from the code.

Report to the user:

```markdown
## Test plan: {scope}

**Corpus:** {path} · **Commit:** {sha} · **Shell:** {shell} · **Mode:** {mode}

| Area | Cases | safe / live | human-visual / agent / suite |
|---|---|---|---|
| setup | 12 | 10 / 2 | 0 / 12 / 0 |
| ... | ... | ... | ... |

**Live cases ({N})** — each with its gate and blast radius:
- `money-004` — charges a real card · gate: `STRIPE_LIVE_KEY`

**Thin areas:** {areas with < 3 cases, or "none"}
**Ungrounded surfaces ({N}):** {the list — what a second pass should chase}

**Next:** /smoke-form on the {N} human-visual cases · {N} suite cases ready for /create-issue
```

Do NOT commit the corpus unless the user asks. Do NOT push.

## Comparison to sister skills

| Need | Use |
|---|---|
| "What is testable in this whole codebase?" | `/test-plan` |
| "Render a checklist a human can click through" | `/smoke-form` |
| "Verify what changed in the last few PRs" | `/smoke-form` |
| "Run an automated browser pass" | `/smoke-test` |
| "Capture bugs while I dogfood" | `/manual-testing-mode` |
| "Find bugs to file as issues" | `/bug-hunt` |
| "Where do I even start in this repo?" | `/recon` |

A typical pipeline: `/recon` → `/test-plan` → `/smoke-form` for the human-visual
stream, `/create-issue` for the `suite` stream.

## Customization Points

- **Default corpus directory** (section: Output location) — where generated
  plans live in this repo.
- **Target shell(s)** (section 2) — what maintainers and testers actually run,
  so `shell=auto` has a documented fallback.
- **Extra surface areas** (section 3) — real areas this repo has that the
  generic taxonomy misses. Only ones the repo actually has.
- **The real-side-effect gate** (section 6) — the env var / credential / flag
  separating test-mode from live, plus anything never safe to exercise here.
- **Existing automated coverage** (section 7) — what the suite already covers
  and the command that runs it, so `suite` cases are genuine gaps.
