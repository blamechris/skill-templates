# /project-genesis

Start a new fleet repo to the Fleet Project Genesis Standard v1, or audit or extend an existing one against it. Genesis creates the GitHub repo, applies the settings, ruleset and labels, scaffolds the core files plus any stack overlays and modules, writes the skill profile and installs the registry skill set, provisions the runner, files every manual step as a `human-setup` issue, and opens one scaffold PR for the owner to merge. It **orders existing tools and re-implements none of them**: `fleet-check.py`, `/skill`, `/skill-profile`, `/create-issue`, `/create-pr`, `provision-runner.sh` and `/session-lifecycle` each do their own job. The only new logic is `genesis-verify.py`, which renders the plan and decides when genesis is done.

Every phase is **probe → act only on what is missing → re-probe**. Nothing records how far genesis got, so re-running the command is how you resume.

## Arguments

- `$ARGUMENTS` — exactly one mode:
  - `<name>` — **create mode**. `<name>` is the repo slug: lower-case letters, digits and inner hyphens. It is final before anything exists, because the seed scope, the runner directory and the app ID all key off it. Flags, each passed to `genesis-verify.py --plan` only when the owner gives it:
    - `--stack none|kotlin` — default `none`. Name a stack only when an owner decision already does. The standard's other overlays are `planned` in v1, and the plan refuses them by name.
    - `--modules <list>` — default `runner-mac,repo-memory,repo-relay`. v1 implements `runner-mac`, `repo-memory`, `repo-relay` and `credits`. **`runner-mac` is required**: every CI job routes to the self-hosted Mac by default, and without a runner the scaffold PR's `ci-gate` never runs.
    - `--app-id <reverse-dns>|none` — default `com.blamechris.<slug without separators>` when an app overlay is chosen, otherwise `none`.
    - `--visibility private` — the only visibility v1 implements. `public` is `planned` and refused.
    - `--posture withheld|gated` — default `withheld`.
    - `--description "<one line>"` — the GitHub description and the README lead.
    - `--seed-issues <path>` — an owner-supplied Markdown file: one `## <title>` per issue, then its body, then a `Labels: a, b` line.
    - `--dry-run` — Phase 0 only: print the plan and write nothing outside the session scratchpad.
  - `--audit [--json] [--file-issues]` — conformance of the current repo. Read-only unless `--file-issues` is given.
  - `--add overlay:<x>|module:<y>` — apply one layer to the current, already-conformant repo.

## Instructions

### Resolving the registry, and running skills before they are installed

Genesis reads its templates, manifest, labels and ruleset from the registry's `origin/main`, never from the registry clone's working tree, which is a shared working copy that may sit on another session's branch. Resolve the clone the way `/skill` does:

```bash
REG="${SKILL_REGISTRY_DIR:-$HOME/Projects/skill-templates}"
git -C "$REG" fetch -q origin || { echo "REFUSE: registry clone at $REG cannot fetch"; exit 2; }
git -C "$REG" cat-file -e origin/main:assets/genesis/standard-v1.json \
  || { echo "REFUSE: registry origin/main has no Genesis Standard v1 manifest"; exit 2; }
```

Genesis needs a **local clone**, because it reads many files. If `/skill`'s resolution order would fall through to `gh api`, stop and ask the owner to clone the registry. Do not assemble the templates file by file over the API.

**Before Phase 4, a skill this one composes runs from its registry template.** Genesis itself, `/create-issue` and `/skill-profile` have not been installed into the new repo yet. So read `git -C "$REG" show origin/main:generic/<name>.md` and follow it, taking each customization marker's generic default. From Phase 4 on, use the installed copies under the worktree's `.claude/commands/`.

**The plan JSON is the single source of every value genesis writes.** Settings, labels, the ruleset, files, the profile inputs, skills, machine steps and issues all come from `$PLAN_JSON`, which `genesis-verify.py` renders from the manifest at one registry commit. Genesis never types a setting, a label or a colour of its own.

### Shell state: re-derive it in every block

Agent shells keep **nothing** between calls: not variables, not functions, not the working directory. A block that relies on an earlier block's `$WT` silently runs `cd ""` and writes into the wrong checkout, and a missing helper function exits 127, which an `&&` chain reads as "nothing to do". So **start every block below with this preamble**, with the repo name typed literally. Everything in it is derived from the name and the registry; it records no progress.

```bash
NAME=<name>                                   # the literal slug, every time
REG="${SKILL_REGISTRY_DIR:-$HOME/Projects/skill-templates}"
R="blamechris/$NAME"
G="${GENESIS_SCRATCH:-${TMPDIR:-/tmp}/genesis-$NAME}"   # session scratchpad, never a repo
PLAN_JSON="$G/plan.json"; VERIFY_JSON="$G/verify.json"; WRITTEN="$G/written.txt"
GV="$G/genesis-verify.py"                     # extracted in Phase 0 from the plan's registry commit
PLAN_REF=$(jq -r '.registry.commit // empty' "$PLAN_JSON" 2>/dev/null)
SESSION_BRANCH=$(cat "$G/branch" 2>/dev/null); EPIC=$(cat "$G/epic" 2>/dev/null)
WT=${SESSION_BRANCH:+${GENESIS_WT_ROOT:-${TMPDIR:-/tmp}}/$NAME-genesis-${SESSION_BRANCH##*/}}
failed() { jq -e --arg r "$1" '.results[] | select(.rule == $r) | .result == "FAIL"' "$VERIFY_JSON" >/dev/null; }
put() { jq "$2" "$PLAN_JSON" | gh api -X PUT "repos/$R/$1" --input - --silent; }
epic_plan() { gh issue view "${EPIC:?}" -R "$R" --json body -q .body | awk '/^```genesis-plan/{f=1;next} /^```/{f=0} f'; }
```

Any block that writes guards its inputs first, so an unset value aborts instead of expanding to `""`: `: "${WT:?}" "${SESSION_BRANCH:?}" "${PLAN_JSON:?}"`. `WT` stays empty until Phase 1 has chosen a branch, so that guard really fires. `$G/branch`, `$G/epic` and `$G/relay-token-in` hold values Phase 0 and Phase 1 chose, which later blocks cannot re-derive for free. They are inputs, not progress markers. Write `${VAR}` rather than `$VAR` wherever a colon follows: zsh, which is the agent's shell, reads `"$PLAN_REF:a…"` as a history modifier.

Every `/skill`, `/skill-profile`, `/create-issue` and `/create-pr` step below runs with **the worktree as the repo root**. Run it as `cd "${WT:?}" && …`, and assert the branch before it writes.

### Phase 0: Preflight and Plan (read-only)

Nothing in this phase writes to GitHub, the machine's configuration or any repo. Its only files are in the session scratchpad `$G`.

1. **Auth scopes.** `gh auth status` must show the `repo` and `workflow` scopes. If either is missing, stop and tell the owner to run `gh auth refresh -s repo,workflow`.
2. **Floor check**, against the resolved clone rather than the script's default path:
   ```bash
   python3 ~/.claude/scripts/fleet-check.py --repo "$REG"; FC=$?
   ```
   `1` is FLOOR drift: stop and reconcile first. `2` means it could not verify: stop, say so, and never proceed as if it passed. `0` with default drift is information; name it and continue.
3. **Machine scripts.** `~/.claude/scripts/session-seed.py`, `~/.claude/scripts/filed-from.py`, `~/github-runners/provision-runner.sh` and `~/github-runners/fleet-status.sh` must exist. Note whether `~/.claude/scripts/genesis-verify.py` is byte-identical to `origin/main`'s copy. If it is not, its bootstrap copy is approved write #1, done in Phase 1, so that later `--audit` runs have it.
4. **Create or resume.** The epic title comes from the manifest, and only an exact title match counts:
   ```bash
   mkdir -p "$G"
   EPIC_TITLE=$(git -C "$REG" show origin/main:assets/genesis/standard-v1.json | jq -r .epic_title)
   EPIC=""
   if gh repo view "$R" >/dev/null 2>&1; then
     EPIC=$(gh issue list -R "$R" --state all --label epic --limit 200 --json number,title \
       | jq -r --arg t "$EPIC_TITLE" '.[] | select(.title == $t) | .number' | head -1)
   fi
   if [ -n "$EPIC" ]; then
     echo "$EPIC" > "$G/epic"                           # resume
   else                                                 # fresh create: nothing from an earlier run may pin it
     rm -f "$G/plan.json" "$G/verify.json" "$G/written.txt" "$G/branch" "$G/epic" "$G/relay-token-in" "$G/genesis-verify.py"
   fi
   ```
   - **The repo exists and has the epic: this is a resume.** The epic body carries the approved intent in a fenced `genesis-plan` block (`epic_plan` prints it), including the registry commit and date the plan was rendered at. Step 6 re-renders from exactly that block, and step 5 is skipped. If the arguments given now differ from the recorded intent, stop and ask; never silently re-plan.
   - **The repo exists without the epic.** Genesis files the epic seconds after creating the repo, so this is almost always a repo genesis did not make: REFUSE, and point to `--audit` or `--add`. The one exception is a repo whose only branch is `main` and whose only commit is GitHub's own README commit. There, genesis may have stopped between those two steps. Ask the owner whether to adopt it, and continue only on an explicit yes.
   - **`~/Projects/$NAME` exists but is not a git checkout of `$R`: REFUSE.** Never delete or reuse it.
5. **Secret reuse (names only).** Only in a fresh create, never on a resume. For `repo-relay`, find the sibling repos that already hold the bot token. The API returns secret **names** only, never values. Step 6 reads the result from a file, because a variable does not survive to its block:
   ```bash
   for r in $(gh repo list blamechris --limit 200 --json name -q '.[].name'); do
     [ "$r" = "$NAME" ] && continue
     gh secret list -R "blamechris/$r" --json name -q '.[].name' 2>/dev/null | grep -qx DISCORD_BOT_TOKEN && echo "$r"
   done | paste -sd, - > "$G/relay-token-in"
   ```
6. **Plan.** Pin one registry commit and use it for both the manifest and the script that reads it. A newer script need not render an older manifest, so resumes and the final verify use this same pair. The commit is chosen by mode, never inherited from an earlier run:
   ```bash
   if [ -n "${EPIC:-}" ]; then PLAN_REF=$(epic_plan | jq -r .registry_commit)     # resume
   else PLAN_REF=$(git -C "$REG" rev-parse origin/main); fi                   # fresh create
   git -C "$REG" show "${PLAN_REF}:assets/scripts/genesis-verify.py" > "$GV" && test -s "$GV" \
     || { echo "REFUSE: cannot extract genesis-verify.py at ${PLAN_REF:-<no commit>}"; exit 2; }
   ```
   **On a resume**, the arguments are the epic block's recorded intent, every one of them: `--stack` (its overlays, or `none`), `--modules`, `--app-id`, `--visibility`, `--posture`, `--description`, `--date` and `--relay-token-in` (its list, or `none`). The render is then byte-identical. **On a fresh create**, build the arguments from the flags the owner actually gave. An absent flag must stay absent, both so the manifest supplies the default and so the Decisions table can show which choices were defaulted:
   ```bash
   RELAY_IN=$(cat "$G/relay-token-in" 2>/dev/null)
   ARGS=(--plan --registry "$REG" --registry-ref "$PLAN_REF" --name "$NAME" --relay-token-in "${RELAY_IN:-none}")
   [ -n "${STACK:-}" ]       && ARGS+=(--stack "$STACK")
   [ -n "${MODULES:-}" ]     && ARGS+=(--modules "$MODULES")
   [ -n "${APP_ID:-}" ]      && ARGS+=(--app-id "$APP_ID")
   [ -n "${VISIBILITY:-}" ]  && ARGS+=(--visibility "$VISIBILITY")
   [ -n "${POSTURE:-}" ]     && ARGS+=(--posture "$POSTURE")
   [ -n "${DESCRIPTION:-}" ] && ARGS+=(--description "$DESCRIPTION")
   python3 "$GV" "${ARGS[@]}" --json > "$PLAN_JSON"; RC=$?
   ```
   Exit `2` is a REFUSE, such as a planned layer, a missing `runner-mac`, an invalid app ID or a bad slug. Show its stderr and stop. On `0`, present the plan exactly as the script prints it:
   ```bash
   python3 "$GV" "${ARGS[@]}"
   ```
   That output is the write table plus the **Decisions** table, which lists every choice with its value, recommendation, reason and whether it was defaulted. Do not hand-build either table.
7. **Seed issues.** If `--seed-issues` was given, parse it now. Every entry needs a title, a body and a `Labels:` line whose labels all appear in the plan's `.github.labels`. Any other shape is a REFUSE, naming the entry.

**Wait point 1.** Stop and wait for the owner's explicit approval of this plan. `--dry-run` ends here.

### Phase 1: Create, File the Epic, Anchor

1. **Bootstrap**, only if step 3 found the machine copy stale:
   ```bash
   git -C "$REG" show origin/main:assets/scripts/genesis-verify.py > ~/.claude/scripts/genesis-verify.py
   ```
2. **Create the repo** only if it is absent. GitHub's README commit is the only commit that does not arrive through a PR:
   ```bash
   CREATE=(gh repo create "$R" "--$(jq -r .intent.visibility "$PLAN_JSON")" --add-readme)
   DESC=$(jq -r '.intent.description // ""' "$PLAN_JSON"); [ -n "$DESC" ] && CREATE+=(--description "$DESC")
   gh repo view "$R" >/dev/null 2>&1 || "${CREATE[@]}"
   ```
3. **Create the canonical checkout** only if it is absent:
   ```bash
   test -d "$HOME/Projects/$NAME/.git" || git clone "git@github.com:$R.git" "$HOME/Projects/$NAME"
   git -C "$HOME/Projects/$NAME" fetch --prune origin
   ```
4. **File the epic now, before anything else can fail.** The epic is what makes a stopped genesis resumable, so it follows the repo immediately. First create only the `epic` label, from the plan:
   ```bash
   jq -r '.github.labels[] | select(.name == "epic") | [.name, .color, .description] | @tsv' "$PLAN_JSON" \
     | while IFS=$'\t' read -r n c d; do gh label create "$n" --color "$c" --description "$d" --force -R "$R"; done
   ```
   Then follow the registry `/create-issue` template with `--standalone`, **from `~/Projects/$NAME`** (the worktree does not exist yet) and with `-R "$R"` on every `gh` call it makes, so the epic cannot land in another repo:
   - The title is `.epic.title`.
   - The labels are exactly `.epic.labels`. Drop the `enhancement` label the template adds by default.
   - The body is the approved plan: the printed write table and Decisions table, then a fenced block tagged `genesis-plan` holding the output of `jq '{intent, registry_commit: .registry.commit}' "$PLAN_JSON"`. That block is how a resume re-renders the same plan.

   Then write the number to `$G/epic`, and confirm the labels by reading them back:
   ```bash
   echo "$EPIC" > "$G/epic"
   [ "$(gh issue view "$EPIC" -R "$R" --json labels -q '[.labels[].name] | sort | join(",")')" = \
     "$(jq -r '.epic.labels | sort | join(",")' "$PLAN_JSON")" ] || echo "FIX: the epic's labels differ from the plan"
   ```
5. **Choose the branch and create the worktree.** In order:
   - An open genesis PR is resumed on its own branch.
   - Before the scaffold PR merges, work stays on `genesis/scaffold`.
   - After it has merged (`origin/main` carries ADR-0001), each follow-up gets a fresh, time-stamped branch, so it always starts from the current `main`.

   The worktree lives outside `.claude/worktrees/`, which the harness reaps on its own schedule:
   ```bash
   B=$(cat "$G/branch" 2>/dev/null)
   OPEN=$(gh pr list -R "$R" --state open --json headRefName -q '.[].headRefName' | grep -m1 '^genesis/' || true)
   if [ -n "$B" ] && [ -e "${GENESIS_WT_ROOT:-${TMPDIR:-/tmp}}/$NAME-genesis-${B##*/}/.git" ]; then
     :                                   # this session's branch, with its worktree still in place
   elif [ -n "$OPEN" ]; then
     B=$OPEN
   elif git -C "$HOME/Projects/$NAME" cat-file -e origin/main:docs/adr/0001-project-genesis.md 2>/dev/null; then
     B=genesis/followup-$(date -u +%Y%m%d%H%M)
   else
     B=genesis/scaffold
   fi
   echo "$B" > "$G/branch"; SESSION_BRANCH=$B
   WT="${GENESIS_WT_ROOT:-${TMPDIR:-/tmp}}/$NAME-genesis-${B##*/}"
   if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
     :   # reuse the existing worktree; never delete it and start over
   elif git -C "$HOME/Projects/$NAME" ls-remote --exit-code --heads origin "$B" >/dev/null; then
     git -C "$HOME/Projects/$NAME" worktree add -B "$B" "$WT" "origin/$B"   # resume a pushed branch
   else
     git -C "$HOME/Projects/$NAME" worktree add -B "$B" "$WT" origin/main
   fi
   ```
   `-B` resets a stale local branch left behind by an earlier, merged PR. Every earlier phase pushed its work, so nothing that exists only locally can be lost. Once `$G/branch` names a branch with a live worktree, later runs of this step keep it.

### Phase 2: GitHub Settings, Labels, Ruleset

Probe first, then write only what the probe reports as missing. The probe is `genesis-verify.py` itself. It runs against the new repo with the plan's intent and the plan's registry commit, so its GitHub rows say exactly which setting differs from the manifest:

```bash
VFLAGS=(--registry "$REG" --registry-ref "${PLAN_REF:?}" --gh-repo "$R"
  --stack "$(jq -r '.intent.overlays | if length == 0 then "none" else join(",") end' "$PLAN_JSON")"
  --modules "$(jq -r '.intent.modules | join(",")' "$PLAN_JSON")"
  --app-id "$(jq -r .intent.app_id "$PLAN_JSON")" --visibility "$(jq -r .intent.visibility "$PLAN_JSON")")
python3 "$GV" --repo "$HOME/Projects/$NAME" --ref origin/main "${VFLAGS[@]}" --json > "$VERIFY_JSON"; VRC=$?
[ "$VRC" -ne 2 ] && jq -e '.results | length > 0' "$VERIFY_JSON" >/dev/null \
  || { echo "STOP: the probe could not look (ERROR rows below)"; jq -r '.results[]? | select(.result == "ERROR") | "\(.rule): \(.evidence)"' "$VERIFY_JSON"; exit 2; }
```

Exit `2` means the probe could not look, for example because the token lacks admin on the repo. Stop and report it; never write blind. File rows FAIL at this point by design, because the scaffold lands in Phase 3.

1. **Repository settings:**
   ```bash
   { failed github.merge-settings || failed github.features; } \
     && jq '.github.repo + .github.features' "$PLAN_JSON" | gh api -X PATCH "repos/$R" --input - --silent
   ```
2. **Actions and security**, each only when its own rule FAILs:
   ```bash
   failed github.actions           && put actions/permissions '.github.actions_permissions'
   failed github.workflow-token    && put actions/permissions/workflow '.github.workflow_permissions'
   failed github.fork-pr-workflows && put actions/permissions/fork-pr-workflows-private-repos '.github.fork_pr_workflows_private'
   failed github.retention         && put actions/permissions/artifact-and-log-retention '{days: .github.retention_days}'
   if failed github.security; then
     [ "$(jq .github.vulnerability_alerts "$PLAN_JSON")" = true ]     && gh api -X PUT "repos/$R/vulnerability-alerts" --silent
     [ "$(jq .github.automated_security_fixes "$PLAN_JSON")" = true ] && gh api -X PUT "repos/$R/automated-security-fixes" --silent
   fi
   ```
3. **Labels.** When `github.labels` FAILs, create or update the seed labels from the plan:
   ```bash
   failed github.labels && jq -r '.github.labels[] | [.name, .color, .description] | @tsv' "$PLAN_JSON" \
     | while IFS=$'\t' read -r n c d; do gh label create "$n" --color "$c" --description "$d" --force -R "$R"; done
   ```
   Then remove the GitHub defaults listed in `.github.remove_default_labels`. Delete one **only when no issue and no PR carries it**:
   ```bash
   jq -r '.github.remove_default_labels[]' "$PLAN_JSON" | while IFS= read -r L; do
     [ "$(gh issue list -R "$R" --state all --label "$L" --json number -q length)" = 0 ] \
       && [ "$(gh pr list -R "$R" --state all --label "$L" --json number -q length)" = 0 ] \
       && gh label delete "$L" --yes -R "$R"
   done
   ```
4. **Ruleset** (`github.ruleset`, `github.ruleset.no-bypass`). If no ruleset with the document's name exists, create it from the plan:
   ```bash
   RS_NAME=$(jq -r .github.ruleset.name "$PLAN_JSON")
   [ -n "$(gh api "repos/$R/rulesets" --jq ".[] | select(.name == \"$RS_NAME\") | .id")" ] \
     || jq '.github.ruleset' "$PLAN_JSON" | gh api -X POST "repos/$R/rulesets" --input - --silent
   ```
   If a `main` ruleset exists and either rule still FAILs, stop and show the owner the probe's evidence. Never overwrite it, never disable it, and never add a bypass actor.
5. **Re-probe.** Re-run the probe block above. Every `github.*` row must now PASS. If one still fails, stop and report its evidence.

### Phase 3: Scaffold

1. **Assert the branch** immediately before the first write:
   ```bash
   [ "$(git -C "${WT:?}" branch --show-current)" = "${SESSION_BRANCH:?}" ] || { echo "STOP: HEAD moved"; exit 1; }
   ```
2. **Write the rendered files that are missing** from `plan.files`: core, overlays, every enabled module's repo files, and ADR-0001. **Never overwrite a file that already exists.** A resume, a follow-up branch or the owner may already have edited it, and whether it conforms is the probe's call, not the writer's. The single exception is GitHub's own generated `README.md`. The writer also refuses any path that escapes the worktree, and never writes `.claude/skill-profile.md`, which Phase 4 composes:
   ```bash
   python3 - "$PLAN_JSON" "${WT:?}" "$WRITTEN" <<'PY'
   import json, os, sys
   plan, wt, out = json.load(open(sys.argv[1])), os.path.realpath(sys.argv[2]), sys.argv[3]
   name = plan["intent"]["name"]
   def github_readme(text):   # what `gh repo create --add-readme` writes: an H1 and at most a description
       lines = [l for l in text.splitlines() if l.strip()]
       return 0 < len(lines) <= 2 and lines[0].strip() == f"# {name}"
   done, kept = [], []
   for f in plan["files"]:
       if f["phase"] != 3: continue
       dst = os.path.realpath(os.path.join(wt, f["path"]))
       if not dst.startswith(wt + os.sep) or f["path"] == ".claude/skill-profile.md":
           sys.exit(f"REFUSE: {f['path']}")
       if os.path.exists(dst) and not (f["path"] == "README.md" and github_readme(open(dst).read())):
           kept.append(f["path"]); continue
       os.makedirs(os.path.dirname(dst), exist_ok=True)
       open(dst, "w").write(f["content"])
       done.append(f["path"])
   open(out, "w").write("".join(p + "\n" for p in done))
   print(f"wrote {len(done)}; left {len(kept)} existing file(s) alone: {', '.join(kept) or 'none'}")
   PY
   ```
3. **Review the tree.** Run `git -C "$WT" status --short --untracked-files=all`, which lists every file individually. Anything listed that is not in `$WRITTEN` is not yours: report it and leave it alone.
4. **Assert the branch again, then stage explicit paths.** Stage only the paths the writer listed, by name:
   ```bash
   [ "$(git -C "${WT:?}" branch --show-current)" = "${SESSION_BRANCH:?}" ] || exit 1
   if [ -s "$WRITTEN" ]; then
     tr '\n' '\0' < "$WRITTEN" | xargs -0 git -C "$WT" add --
     git -C "$WT" commit -m "chore: scaffold ${NAME} to Fleet Genesis Standard v1"
   fi
   [ -n "$(git -C "$WT" log --oneline origin/main..HEAD)" ] && git -C "$WT" push -u origin "$SESSION_BRANCH"
   ```
   On a resume where nothing is missing, this phase writes nothing and pushes nothing. A branch with no commits over `main` is never pushed.

### Phase 4: Profile and Skills

Profile first: nothing is installed until the step 2 check passes.

1. **Compose the profile.** Run the registry `/skill-profile` template in planned mode from the worktree, giving it the install set and the plan:
   ```
   /skill-profile --planned "<every skill in plan.skills.install, in order>" --plan "$PLAN_JSON"
   ```
   It writes the repo-wide sections, the posture pins, the merge-strategy lines, the seed labels for `create-issue`, and `plan.profile.section` verbatim as `## project-genesis Customizations`. Every value comes from the plan. If one is unknown, it is omitted.
2. **Check the pin mechanically** before the first install. Both posture sections must lead with the planned bold declaration:
   ```bash
   POSTURE=$(jq -r .profile.posture "$PLAN_JSON")   # Withheld or Gated
   [ "$(grep -A3 '^### Self-merge posture' "${WT:?}/.claude/skill-profile.md" | grep -c "\*\*$POSTURE\.\*\*")" -ge 2 ] \
     || { echo "STOP: the posture pin is missing"; exit 1; }
   ```
3. **Install**, group by group from `plan.skills.install`. Run `/skill add <name>` for each; `/skill` runs `skill-lint.sh` and compiles targets, and a lint exit other than 0 stops the phase. Leave the skills in `plan.skills.deferred` uninstalled. The profile's `deferred-skills:` line records them **by name only**, while their triggers live in the manifest.
4. **Done-check.** `/skill outdated` must report no version drift and no profile drift for any installed skill.
5. **Assert the branch, then stage explicit paths.** Run `git -C "$WT" status --short --untracked-files=all`, which lists files rather than directories. Stage every path it shows under `.claude/` (plus `.gemini/` or `.codex/` if they are targets) and `scripts/compile-skill-targets.mjs`, **each by name**. Never a directory, never `-A`, `.`, `-u` or `commit -a`. Then commit `chore(skills): install registry skill set` and push.

### Phase 5: Machine, Modules and Issues (no repo writes)

1. **Machine steps.** Run every `plan.machine` entry with `phase` 5, in order. Today that is `provision-runner.sh <name>` then `fleet-status.sh --md`, from `runner-mac`.
2. **Issues.** File every `plan.issues` entry under the epic, then each `--seed-issues` entry. Use the installed `/create-issue --from-issue $EPIC`, and give each issue **exactly** its entry's labels. Drop the `enhancement` label the create-issue template adds by default unless the entry lists it:
   - **A work issue** is the SPEC issue, which is always filed, or the credits issue when `credits` is on. Its body is the create-issue shape: `## Context` with `Filed from: #$EPIC`, then `## Description` holding the entry's `description`, then `## Acceptance Criteria` as a checklist of its `acceptance`.
   - **A `human-setup` issue** has the body `## Context` with `Filed from: #$EPIC`, followed by the entry's `body` verbatim: What · Why a human · Exact steps · Secret names · Reuse or create · Done when. Pass the body through a file (`jq -r '.issues[N].body' "$PLAN_JSON"`), never retyped.

   Read each issue's labels back (`gh issue view <n> -R "$R" --json labels`) and correct any that differ from its entry with `gh issue edit --add-label/--remove-label`.
3. **Re-probe the human steps.** Run the Phase 2 probe block again. Every rule the manifest marks `human` must read PASS or PENDING-HUMAN, never FAIL. PENDING-HUMAN is how the probe proves the issue it matched carries the backticked rule ID in its "Done when". A FAIL here means that issue did not land as rendered: fix the issue body, not the probe.
4. **Assert a clean tree.** Phase 5 writes no repo files. If `git -C "$WT" status --short --untracked-files=all` prints anything, stop: a module's repo file belongs in Phase 3.

### Phase 6: PR, Verify and Hand Off

1. **Open the PR.** From the worktree, run the installed `/create-pr`. The body references `Refs #$EPIC`, not `Fixes`, because the epic closes only when verification passes.
2. **Review at LOW tier.** Run an inline `/code-review` at high effort, with no subagent fan-out. The templates were reviewed at HIGH in the registry; only per-repo values are new.
3. **Wait for CI.** `gh pr checks --watch` exits at once while no required check has been reported yet, so first wait for `ci-gate` to appear. That wait is bounded to stay inside one tool call:
   ```bash
   PR=$(gh pr list -R "$R" --head "${SESSION_BRANCH:?}" --state open --json number -q '.[0].number'); : "${PR:?no open PR for $SESSION_BRANCH}"
   seen=""; for _ in $(seq 40); do
     gh pr checks "$PR" -R "$R" --required --json name -q '.[].name' 2>/dev/null | grep -qx ci-gate && { seen=1; break; }
     sleep 10
   done
   [ -n "$seen" ] || { echo "STOP: ci-gate has not appeared after ~7 minutes; is the runner online?"; exit 1; }
   gh pr checks "$PR" -R "$R" --required --watch
   ```
   On a failure, use the installed `/fix-ci`. `ci-gate` is the only required check. If it never appears because no runner picks the jobs up, the runner from Phase 5 is not online; fix that rather than routing around it.
4. **Wait point 2: the owner merges.** Genesis never merges its own PR, whatever the posture, and never uses `--admin` or `--auto`.
5. **Verify on `origin/main`**, with the same pinned script and registry commit the plan was rendered from. In a new session, `PLAN_REF` is the `registry_commit` in the epic's `genesis-plan` block:
   ```bash
   git -C "$HOME/Projects/$NAME" fetch origin
   python3 "$GV" --repo "$HOME/Projects/$NAME" --ref origin/main --registry "$REG" --registry-ref "${PLAN_REF:?}" \
     --json > "$VERIFY_JSON"; GVRC=$?
   ```
   - `0`: close the epic with the verify table as its comment. PENDING-HUMAN rows are conformant; their issues stay open.
   - `1`: re-run `/project-genesis $NAME`. That resumes on a `genesis/followup` branch: it probes, writes only what is missing, and opens a follow-up PR.
   - `2`: stop and report that verification could not run, naming the ERROR rows. It is never treated as a pass.
6. **Canonical checkout.** If `~/Projects/$NAME` is clean and on `main`, run `git -C "$HOME/Projects/$NAME" merge --ff-only origin/main`. Then run every `plan.machine` entry with `phase` 6. Today that is the `repo-memory` index prewarm, run in `~/Projects/$NAME`.
7. **Tear down the worktree.** Nothing durable lives in it; everything was pushed at each phase boundary:
   ```bash
   git -C "$HOME/Projects/$NAME" worktree remove --force "${WT:?}"
   ```
8. **Priorities.** Print a suggested `~/Projects/PRIORITIES.md` line for the owner to paste. Never write it.
9. **Hand off.** Run `/session-lifecycle end` **from `~/Projects/$NAME`**, so the seed's scope resolves to the new repo and not to `fleet`. Use `--picks-up-at "#<SPEC issue> — land docs/design/SPEC.md"`. Genesis itself writes no seed file.
10. **Report.** Give the PR, the epic, the open `human-setup` issues and the verify result. End the message with the mechanical `**Status:**` block — the four fixed slots defined in the global `~/.claude/CLAUDE.md` ("End-of-message summary"); follow it from there rather than restating it.

### Mode: `--audit`

1. The machine copy of the script may be missing or stale, so this block resolves the registry and extracts the current script itself. A failed extraction is "could not verify", never a pass:
   ```bash
   REG="${SKILL_REGISTRY_DIR:-$HOME/Projects/skill-templates}"; G="${TMPDIR:-/tmp}/genesis-audit"; mkdir -p "$G"
   git -C "$REG" fetch -q origin && git -C "$REG" show origin/main:assets/scripts/genesis-verify.py > "$G/genesis-verify.py" \
     && test -s "$G/genesis-verify.py" || { echo "could not verify: no genesis-verify.py from $REG"; exit 2; }
   python3 "$G/genesis-verify.py" --repo . --ref origin/main --registry "$REG" [--json]
   ```
   A genesis repo supplies its own intent from the profile. A repo that predates the standard has none, so pass the layers it actually has (`--stack`, `--modules`, `--app-id`). Otherwise every overlay and module rule reads N-A.
2. Print the table: rule ID, result (PASS / FAIL / WAIVED / N-A / LEGACY / PENDING-HUMAN / ERROR) and evidence.
3. With `--file-issues`, file one `/create-issue "<rule>: <finding>" --label tech-debt --label from-audit` per **FAIL** row, after the duplicate check. File nothing for ERROR rows and nothing at all on exit 2. Never fix anything, never delete anything, and never change a setting in audit mode.
4. Exit with verify's code. A `2` is reported as "could not verify", never as clean.

### Mode: `--add overlay:<x>|module:<y>`

1. The repo must pass `--audit` apart from the layer being added. Otherwise stop and report.
2. Re-run Phase 0 with these inputs:
   - the profile's recorded intent plus the new layer;
   - `--posture` read from the profile's own `### Self-merge posture` pins, because a re-plan must never change a pin;
   - `--date` taken from ADR-0001;
   - the current registry, with `PLAN_REF` set explicitly to the current `origin/main` commit.

   Present only the delta and wait for approval.
3. Work on a branch named `genesis/add-<layer>` and run Phases 2–6 restricted to that layer:
   - **A module:** write the files in `plan.files` whose `layer` is that module. The Phase 3 writer already leaves existing files alone.
   - **An overlay:** it also changes core files through its fragments (`ci.yml`, `.gitignore`, `.gitattributes`, `dependabot.yml`). Show the owner the diff of each against the repo's current copy, and write them only on approval, because the repo may have deliberate local edits there. Never rewrite owner prose (`README.md`, `MISSION.md`, `NON-GOALS.md`, ADRs).
   - **The profile:** replace only the `## project-genesis Customizations` section with the plan's `.profile.section`. Keep the section's existing `credits-paths:` and `waivers:` lines verbatim, because the owner maintains them and the plan knows neither. Touch nothing else in the profile: sections added since genesis, such as a Status line or a per-skill footgun, are the owner's. Then assert the branch and stage the profile by name.
   - **Deferred skills:** when the layer is an overlay, install the deferred skills whose trigger it meets, then run `/skill update` for any skill whose profile hash moved.

## Error Recovery

| Error | Recovery |
|---|---|
| `fleet-check.py` exits 1 or 2 | Stop. Reconcile floor drift, or restore registry visibility, before starting. |
| `--plan` exits 2 (REFUSE) | Show its stderr. A planned layer, a missing `runner-mac` or an invalid app ID is the owner's decision to change, not genesis's. |
| The repo exists without an epic | Not a genesis repo: use `--audit` or `--add`. The only exception is a README-only repo that genesis may have stopped on, and only with the owner's yes. |
| A probe exits 2 or reads ERROR | The probe could not look, often because the token lacks admin on the repo. Fix access, then re-probe. Never write blind. |
| A variable reads empty, or a helper is "not found" | The shell was new. Re-run the preamble; never let `cd ""` or a missing `failed` stand in for a result. |
| A `git show` path comes out mangled in zsh | A `$VAR:x` modifier expanded. Write `${VAR}:path`. |
| HEAD is not `SESSION_BRANCH` | Stop writing, re-establish the branch, then re-probe. |
| A `main` ruleset differs from the document | Report the probe's evidence; the owner decides. Never overwrite. |
| `skill-lint` exit ≠ 0 on an install | Fix the profile value it names, then `/skill add` again. Never hand-edit the installed file. |
| `ci-gate` never appears or stays Pending | Bring the Phase 5 runner online. `[github]` is the break-glass for a runner that is down, not a substitute for provisioning one. |
| The session dies mid-phase | Re-run the same command. The epic's `genesis-plan` block re-renders the same plan from the same registry commit, and the probes find where genesis stopped. |

## Critical Rules

1. **NO attribution** — the Zero Attribution Policy applies to every commit, PR and issue genesis creates.
2. **The profile is written before any skill is installed.** Without a pinned posture, a skill installs gated. Phase 4 step 2 checks the pin before the first `/skill add`.
3. **No GitHub object is created or changed until the owner approves the Phase 0 plan.** Phase 0 is read-only, and `--dry-run` stops there.
4. **Progress is probed, never stored.** There is no state file, no `--resume`, and no progress note in the vault or a worktree. Intent lives in the epic body before the merge and in the committed profile after it.
5. **Every step that needs a human becomes a `human-setup` issue.** Each carries a "Done when" rule ID, and none stays as a chat checklist.
6. **Genesis never reads, prints, or writes a secret value.** It lists secret names only, and the owner types every `gh secret set`.
7. **Nothing is ever pushed to `main`.** All genesis content lands through the scaffold PR. The only exception is GitHub's own `--add-readme` commit.
8. **Genesis is done only when `genesis-verify.py` exits 0 on `origin/main`.** An exit of 2 is never a pass.
9. **Genesis never writes a seed or derives a scope; `/session-lifecycle end` does, through `session-seed.py`.**
10. **The ruleset has no bypass actors.** Genesis never uses `--admin` or `--auto` and never disables a ruleset; the break-glass is the `[github]` routing tag.
11. **Stage explicit paths only.** Assert the branch before the first write and again before staging. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a`.
12. **Real values only, and all of them from the plan.** Never type a setting, label, colour, command, check name, persona or issue that `$PLAN_JSON` does not carry. If a value is unknown, omit it.
13. **Never delete** a repo, a directory, a runner, or a label in use, and **never overwrite** a file that already exists in the repo. **Never change a repo's visibility.** Never register a self-hosted runner on a public repo before fork-PR hardening.

## When NOT to use this skill

- **Adding a feature to an existing repo:** use `/start-working` or `/tackle-issues`.
- **Re-tailoring skills after a convention change:** use `/skill-profile` and then `/skill update`.
- **A repo that predates the standard:** use `--audit` only. Back-porting is per-repo and owner opt-in, never automatic.

## Customization Points

None. This skill carries no customization markers. Its per-repo input is the profile's `## project-genesis Customizations` section, which it writes itself and reads at run time. A value frozen into the installed copy would be a second source of truth for the same intent.
