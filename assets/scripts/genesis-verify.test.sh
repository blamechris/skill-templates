#!/usr/bin/env bash
# Regression tests for assets/scripts/genesis-verify.py.
#
# The load-bearing property is the ROUND TRIP: the files `--plan` renders, written into a
# repo, verify clean against the rules the same manifest declares. One renderer serves
# plan and audit; if they ever disagree, a freshly created repo fails its own genesis.
#
# Around that:
#   - every probed rule has a mutation here that turns it FAIL (checked at the end against
#     `--list-rules`, so a new rule without a mutation fails this suite, not just review);
#   - anything that stops verify from LOOKING — an unreadable registry, a ref that does not
#     resolve, a failed fetch, `gh` answering 401 — exits 2, never 0 or 1;
#   - `--self-check` (the rule<->probe parity CI runs) fails for each defect it names;
#   - verify is read-only: the fake `gh` refuses any write flag, and --plan never calls it.
#
# No network: the registry is a committed copy of this tree's genesis assets, the consumer
# repo is local, and `gh` is a fake that serves fixture files by endpoint.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUT="$HERE/genesis-verify.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/genesis-verify-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
flat() { printf '%s' "$1" | tr '\n' '|' | cut -c1-600; }

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-fixture}"; }

# ---------------------------------------------------------------- the registry fixture
REG="$TMP/registry"
mkdir -p "$REG/assets"
cp -R "$ROOT/assets/genesis" "$REG/assets/"
cp "$ROOT/assets/global-CLAUDE.md" "$REG/assets/"
git -C "$REG" init -q && commit_all "$REG" registry

V() { python3 "$SUT" --registry "$REG" --registry-ref HEAD --no-fetch "$@"; }

# ---------------------------------------------------------------- the fake gh
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Serves `gh api -H <header> <endpoint>` from $FAKE_GH_DIR/<endpoint with /?&= as _>.<kind>.
# A write flag is a test failure by construction: genesis-verify must be read-only.
d=${FAKE_GH_DIR:?FAKE_GH_DIR unset}
printf '%s\n' "$*" >> "$d/calls.log"
[ "${1:-}" = api ] || { echo "fake gh: unexpected: $*" >&2; exit 97; }
shift; ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    -X|--method|-f|-F|--field|--raw-field|--input) echo "fake gh: WRITE flag $1" >&2; exit 98 ;;
    *) ep=$1; shift ;;
  esac
done
key=$(printf '%s' "$ep" | tr '/?&=' '____')
if [ -f "$d/$key.json" ]; then cat "$d/$key.json"; exit 0; fi
if [ -f "$d/$key.204" ]; then exit 0; fi
if [ -f "$d/$key.404" ]; then echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
if [ -f "$d/$key.401" ]; then echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; fi
echo "fake gh: no fixture for $ep" >&2; exit 1
SH
chmod +x "$FAKEBIN/gh"

# ---------------------------------------------------------------- the conformant fixture
PLAN="$TMP/plan.json"
V --plan --json --name soundbed --stack kotlin --modules runner-mac,repo-memory,repo-relay,credits \
  --app-id com.blamechris.soundbed --relay-token-in chroxy,archery-apprentice --date 2026-09-26 > "$PLAN" \
  || { echo "cannot render the fixture plan"; exit 1; }

BASE="$TMP/base"
mkdir -p "$BASE" && git -C "$BASE" init -q
python3 - "$PLAN" "$BASE" <<'PY'
import json, os, sys
plan, root = json.load(open(sys.argv[1])), sys.argv[2]
def put(path, text):
    p = os.path.join(root, path); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
for f in plan["files"]:
    put(f["path"], f["content"])
posture = plan["profile"]["posture"]
put(".claude/skill-profile.md", "\n".join([
    "# soundbed skill profile", "",
    "## Project Context", "- Tech: undecided — see SPEC", "- Repo: blamechris/soundbed", "- CI: ci-gate", "",
    "## Build / Test Commands", *plan["profile"]["build_commands"], "",
    "## Conventions", "- Branch prefix / naming: <type>/<issue>-<slug>", "",
    "## Skill Targets", "targets: claude", "",
    *[l for s in plan["profile"]["posture_sections"] for l in (
        f"## {s} Customizations", "", "### Self-merge posture", "",
        f"**{posture}.** Every merge in this repo is a human act.", "")],
    *[l for s in ("merge", "batch-merge") for l in (
        f"## {s} Customizations", f"- Merge strategy: {plan['profile']['merge_strategy']}", "")],
    plan["profile"]["section"], ""]))
skills = [s for g in plan["skills"]["install"] for s in g]
put(".claude/skills.lock", json.dumps({"registry": "blamechris/skill-templates", "skills": {
    s: {"hash": "0000000", "installed": "2026-09-26", "targets": ["claude"]} for s in skills}}, indent=2))
for s in skills:
    put(f".claude/commands/{s}.md", f"# /{s}\n")
PY
commit_all "$BASE" scaffold

GHBASE="$TMP/gh-base"; mkdir -p "$GHBASE"
python3 - "$GHBASE" "$REG/assets/genesis" <<'PY'
import json, os, sys
d, g = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(g, "standard-v1.json")))
R = "repos_blamechris_soundbed"
def put(key, obj, kind="json"):
    open(os.path.join(d, f"{key}.{kind}"), "w").write("" if obj is None else json.dumps(obj))
repo = {"private": True, "visibility": "private", "default_branch": "main", "permissions": {"admin": True, "pull": True},
        **man["github"]["repo"], **man["github"]["features"]}
put(R, repo)
put(f"{R}_actions_permissions", man["github"]["actions_permissions"])
put(f"{R}_actions_permissions_workflow", man["github"]["workflow_permissions"])
put(f"{R}_actions_permissions_fork-pr-workflows-private-repos",
    {**man["github"]["fork_pr_workflows_private"], "require_approval_for_fork_pr_workflows": False})
put(f"{R}_actions_permissions_artifact-and-log-retention", {"days": 14, "maximum_allowed_days": 90})
put(f"{R}_vulnerability-alerts", None, "204")
put(f"{R}_automated-security-fixes", {"enabled": True, "paused": False})
put(f"{R}_labels_per_page_100_page_1", json.load(open(os.path.join(g, "labels.json"))))
put(f"{R}_rulesets_per_page_100_page_1", [{"id": 42, "name": "main"}])
rs = json.load(open(os.path.join(g, "ruleset-main.json")))
rs["id"] = 42
# The live API returns parameters the document does not set; the probe compares a subset.
for r in rs["rules"]:
    if r["type"] == "pull_request":
        r["parameters"]["require_extra_approval_for_unattributed_changes"] = False
put(f"{R}_rulesets_42", rs)
put(f"{R}_issues_labels_epic_state_all_per_page_100_page_1",
    [{"number": 1, "title": man["epic_title"], "state": "open", "body": "plan"}])
put(f"{R}_issues_labels_human-setup_state_open_per_page_100_page_1", [])
put(f"{R}_actions_runners_per_page_100_page_1",
    {"total_count": 1, "runners": [{"name": "mac-soundbed", "status": "online"}]})
put(f"{R}_actions_secrets_per_page_100_page_1",
    {"total_count": 2, "secrets": [{"name": "DISCORD_BOT_TOKEN"}, {"name": "DISCORD_CHANNEL_PRS"}]})
put(f"{R}_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20",
    {"total_count": 1, "workflow_runs": [{"id": 101, "head_sha": "a" * 40}]})
put(f"{R}_actions_runs_101_jobs_per_page_100_page_1", {"total_count": 3, "jobs": [
    {"name": "route", "conclusion": "success", "labels": ["self-hosted", "macOS", "ARM64"]},
    {"name": "kotlin", "conclusion": "success", "labels": ["self-hosted", "macOS", "ARM64"],
     "runner_name": "soundbed-mbp-arm64"},
    {"name": "ci-gate", "conclusion": "success"},
]})
PY

M="$TMP/mutant"; MG="$TMP/mutant-gh"
# A mutation that does not apply must fail the test, never silently verify the base.
BROKEN=0
fresh() { rm -rf "$M" "$MG"; cp -R "$BASE" "$M"; cp -R "$GHBASE" "$MG"; BROKEN=0; }
verify() { FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --repo "$M" --ref HEAD --gh-repo blamechris/soundbed --json "$@" 2>&1; }
result_of() {  # <json> <rule>
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(next((r["result"] for r in d["results"] if r["rule"]==sys.argv[2]), "ABSENT"))' "$1" "$2" 2>/dev/null || echo UNPARSEABLE
}
edit() {  # <path in $M> <python expression over s>
  python3 - "$M/$1" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
t = eval(expr, {"s": s, "re": __import__("re")})
if t == s:
    sys.exit(f"edit made no change to {p}: {expr}")
open(p, "w").write(t)
PY
  [ $? -eq 0 ] || BROKEN=1
}
gh_edit() {  # <fixture key> <python statement over d>
  python3 - "$MG/$1.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); before = json.dumps(d, sort_keys=True)
exec(sys.argv[2])
if json.dumps(d, sort_keys=True) == before:
    sys.exit(f"gh_edit made no change to {p}: {sys.argv[2]}")
json.dump(d, open(p, "w"))
PY
  [ $? -eq 0 ] || BROKEN=1
}

snap() { git -C "$M" add -A >/dev/null 2>&1; git -C "$M" commit -qm mutant >/dev/null 2>&1; }

COVERED=""
# expect <name> <rule> <RESULT> <exit>: verify the current mutant and assert the rule's row.
expect() {
  local name=$1 rule=$2 want=$3 wantrc=$4 out rc got
  if [ "$BROKEN" -ne 0 ]; then bad "$name" "the mutation did not apply (see the error above)"; return; fi
  git -C "$M" add -A >/dev/null 2>&1; git -C "$M" commit -qm mutant >/dev/null 2>&1
  out=$(verify); rc=$?
  got=$(result_of "$out" "$rule")
  if [ "$got" = "$want" ] && [ "$rc" -eq "$wantrc" ]; then
    ok "$name"
    [ "$want" = FAIL ] && COVERED="$COVERED $rule"
  else
    bad "$name" "rule $rule: $got (want $want), exit $rc (want $wantrc) — $(flat "$out")"
  fi
}

echo "== round trip: plan -> write -> verify"
fresh
out=$(verify); rc=$?
if [ "$rc" -eq 0 ]; then ok "the rendered soundbed plan verifies clean (exit 0)"; else
  bad "the rendered soundbed plan verifies clean (exit 0)" "exit $rc — $(flat "$out")"; fi
summary=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(sorted({r["rule"]+"="+r["result"] for r in d["results"] if r["result"]!="PASS"})))' "$out" 2>/dev/null)
if [ "$summary" = "module.credits.coverage=N-A overlay.kotlin.app-id=N-A" ]; then
  ok "every probed rule PASSes except the two with nothing to probe yet"
else
  bad "every probed rule PASSes except the two with nothing to probe yet" "non-PASS rows: $summary"
fi
if grep -Eq -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$MG/calls.log" || grep -qv '^api -H ' "$MG/calls.log"; then
  bad "verify issues only gh api GETs" "$(head -3 "$MG/calls.log")"
else
  ok "verify issues only gh api GETs ($(wc -l < "$MG/calls.log" | tr -d ' ') calls)"
fi
text=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --repo "$M" --ref HEAD --gh-repo blamechris/soundbed 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$text" | grep -q '| `core.ci-gate` | PASS |' && printf '%s' "$text" | grep -q 'exit 0'; then
  ok "text mode prints the rule table and the exit"
else
  bad "text mode prints the rule table and the exit" "exit $rc — $(flat "$text")"
fi

echo "== core files"
fresh; edit CLAUDE.md 's.replace("## Git workflow\n", "")';                         expect "CLAUDE.md missing a heading" core.claude-md FAIL 1
fresh; edit CLAUDE.md 's + "\n".join(["filler"] * 80)';                              expect "CLAUDE.md over 150 lines" core.claude-md FAIL 1
fresh; edit CLAUDE.md 's.replace("- `worktree-by-default`\n", "")';                  expect "a floor ID dropped from CLAUDE.md" core.claude-md.floor-ids FAIL 1
fresh; edit CLAUDE.md 's.replace("- `worktree-by-default`\n", "- `worktree-by-default`\n- `invented-floor`\n")'; expect "an invented floor ID in CLAUDE.md" core.claude-md.floor-ids FAIL 1
fresh; rm "$M/docs/CLAUDE_REFERENCE.md";                                             expect "CLAUDE_REFERENCE.md removed" core.claude-reference FAIL 1
fresh; edit README.md 's.replace("## Quickstart\n", "")';                             expect "README.md missing Quickstart" core.readme FAIL 1
fresh; edit MISSION.md 're.sub(r"## Why this exists\n(.*?)## What it does\n", lambda m: "## What it does\n" + m.group(1) + "## Why this exists\n", s, count=1, flags=re.S)'; expect "MISSION.md headings out of order" core.mission FAIL 1
fresh; rm "$M/NON-GOALS.md";                                                         expect "NON-GOALS.md removed" core.non-goals FAIL 1
fresh; edit docs/adr/0001-project-genesis.md 's.replace("- **Deciders:** blamechris\n", "")'; expect "ADR-0001 without Deciders" core.adr-0001 FAIL 1
fresh; edit docs/adr/0001-project-genesis.md 's.replace("| App ID | com.blamechris.soundbed |", "| App ID | com.blamechris.other |")'; expect "ADR-0001 reserves a different app ID" core.app-id FAIL 1
fresh; rm "$M/docs/records/README.md";                                               expect "docs/records/ emptied" core.docs-layout FAIL 1
fresh; edit .gitignore 's.replace("*.jks\n", "")';                                   expect ".gitignore without *.jks" core.gitignore FAIL 1
fresh; edit .gitignore 's.replace(".gradle/\n", "")';                                expect ".gitignore without the kotlin overlay line" core.gitignore FAIL 1
fresh; edit .gitattributes 's.replace("*.bat text eol=crlf\n", "")';                 expect ".gitattributes without the kotlin overlay line" core.gitattributes FAIL 1
fresh; edit .github/ISSUE_TEMPLATE/bug_report.md 's.replace("Filed from: none\n", "")'; expect "bug template without Filed from" core.issue-templates FAIL 1
fresh; edit .github/ISSUE_TEMPLATE/human_setup.md 's.replace("## Done when\n", "")';  expect "human-setup template without Done when" core.issue-templates FAIL 1
fresh; edit .github/pull_request_template.md 's.replace("Fixes #\n", "")';            expect "PR template without Fixes #" core.pr-template FAIL 1
fresh; edit .claude/settings.json 's.replace("\"includeCoAuthoredBy\": false", "\"includeCoAuthoredBy\": true")'; expect "co-authored-by switched back on" core.claude-settings FAIL 1
fresh; edit .claude/settings.json 's.replace("\"commit\": \"\"", "\"commit\": \"Generated\"")'; expect "commit attribution set" core.claude-settings FAIL 1

echo "== CI"
fresh; edit .github/workflows/ci.yml 's.replace("needs: [route, hygiene, changes, kotlin]", "needs: [route, changes, kotlin]")'; expect "ci-gate stops needing hygiene" core.ci-gate FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("    if: always()\n", "")';            expect "ci-gate without if: always()" core.ci-gate FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("on:\n  pull_request:\n", "on:\n  pull_request:\n    paths: [\"src/**\"]\n")'; expect "a workflow-level path filter" core.ci-triggers FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("  push:\n    branches: [main]\n", "  push:\n")'; expect "push not restricted to main" core.ci-triggers FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("ls-files -ci --exclude-standard", "ls-files --others")'; expect "hygiene job no longer checks ignored files" core.ci-hygiene FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7", 1)'; expect "an action pinned to a tag" core.actions-pinned FAIL 1
fresh; edit .github/dependabot.yml 's.replace("interval: weekly", "interval: daily", 1)'; expect "github-actions updates not weekly" core.dependabot FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("if: needs.changes.outputs.kotlin == \x27true\x27", "if: true")'; expect "kotlin job not gated on changes" overlay.kotlin.ci FAIL 1
fresh; edit .github/dependabot.yml 's.split("  # Overlay: kotlin")[0]';              expect "no gradle update entry" overlay.kotlin.dependabot FAIL 1

echo "== profile and skills"
fresh; edit .claude/skill-profile.md 's.replace("- standard: v1\n", "")';            expect "intent without standard" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- overlays: kotlin", "- overlays: kotlin, flutter")'; expect "intent naming a planned overlay" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- app-id: com.blamechris.soundbed", "- app-id: com.blamechris.sound-bed")'; expect "intent with an invalid app-id" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("recon, ", "")';                    expect "a deferred skill neither listed nor installed" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("targets: claude\n", "")';          expect "profile without targets" profile.repo-wide FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("**Withheld.**", "**Gated.**", 1)';  expect "the two posture pins disagree" profile.posture FAIL 1
fresh; edit .claude/skill-profile.md 're.sub(r"(## tackle-issues Customizations\n\n)### Self-merge posture\n\n\*\*Withheld\.\*\*", r"\1Posture is up to the agent.", s)'; expect "a posture pin removed" profile.posture FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("## batch-merge Customizations\n- Merge strategy: --squash --delete-branch", "## batch-merge Customizations\n- Merge strategy: --merge")'; expect "batch-merge not pinned to squash" profile.merge-strategy FAIL 1
fresh; edit .claude/skills.lock 's.replace("\"merge-gate\"", "\"merge-gate-old\"")'; expect "an install-set skill missing from the lock" skills.installed FAIL 1
fresh; rm "$M/.claude/commands/fix-ci.md";                                           expect "an installed skill without its command file" skills.installed FAIL 1
fresh; rm "$M/.claude/skill-profile.md"; snap
out=$(verify); rc=$?
if [ "$rc" -eq 1 ] && [ "$(result_of "$out" profile.genesis-intent)" = FAIL ] && [ "$(result_of "$out" overlay.kotlin.ci)" = N-A ]; then
  ok "no profile: intent FAILs and layer rules are N-A, not guessed"
else bad "no profile: intent FAILs and layer rules are N-A, not guessed" "exit $rc — $(flat "$out")"; fi

echo "== GitHub settings"
fresh; gh_edit repos_blamechris_soundbed 'd["private"] = False; d["visibility"] = "public"'; expect "the repo went public" github.visibility FAIL 1
fresh; gh_edit repos_blamechris_soundbed 'd["allow_merge_commit"] = True';               expect "merge commits allowed" github.merge-settings FAIL 1
fresh; gh_edit repos_blamechris_soundbed 'd["allow_auto_merge"] = True';                 expect "auto-merge allowed" github.merge-settings FAIL 1
fresh; gh_edit repos_blamechris_soundbed 'd["has_wiki"] = True';                         expect "wiki on" github.features FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_permissions 'd["sha_pinning_required"] = False'; expect "SHA pinning not required" github.actions FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_permissions_workflow 'd["default_workflow_permissions"] = "write"'; expect "token writable" github.workflow-token FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_permissions_fork-pr-workflows-private-repos 'd["run_workflows_from_fork_pull_requests"] = True'; expect "fork PRs may run workflows" github.fork-pr-workflows FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_permissions_artifact-and-log-retention 'd["days"] = 90'; expect "retention 90 days" github.retention FAIL 1
fresh; mv "$MG/repos_blamechris_soundbed_vulnerability-alerts.204" "$MG/repos_blamechris_soundbed_vulnerability-alerts.404"; expect "Dependabot alerts off (a meaningful 404)" github.security FAIL 1
fresh; gh_edit repos_blamechris_soundbed_automated-security-fixes 'd["enabled"] = False'; expect "security updates off" github.security FAIL 1
fresh; rm "$MG/repos_blamechris_soundbed_automated-security-fixes.json"; : > "$MG/repos_blamechris_soundbed_automated-security-fixes.204"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" github.security)" = ERROR ]; then ok "an empty security-fixes body is ERROR, never read as on or off"
else bad "an empty security-fixes body is ERROR, never read as on or off" "exit $rc — $(flat "$out")"; fi
fresh; gh_edit repos_blamechris_soundbed_labels_per_page_100_page_1 'd[:] = [l for l in d if l["name"] != "human-setup"]'; expect "a seed label missing" github.labels FAIL 1
fresh; gh_edit repos_blamechris_soundbed_labels_per_page_100_page_1 'd[0]["color"] = "ffffff"'; expect "a seed label recoloured" github.labels FAIL 1
fresh; gh_edit repos_blamechris_soundbed_labels_per_page_100_page_1 'd.append({"name": "accessibility", "color": "ededed"})'
out=$(verify); rc=$?
ev=$(python3 -c 'import json,sys; print(next(r["evidence"] for r in json.loads(sys.argv[1])["results"] if r["rule"] == "github.labels"))' "$out" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$(result_of "$out" github.labels)" = PASS ] && [ "$ev" = "all 21 seed labels; also present: accessibility" ]; then
  ok "a label outside the seed set is named in the evidence, never FAILed (#323)"
else bad "a label outside the seed set is named in the evidence, never FAILed (#323)" "exit $rc — $ev"; fi
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'next(r for r in d["rules"] if r["type"] == "pull_request")["parameters"]["allowed_merge_methods"] = ["merge", "squash", "rebase"]'; expect "ruleset allows every merge method" github.ruleset FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'd["rules"] = [r for r in d["rules"] if r["type"] != "required_status_checks"]'; expect "ruleset without required checks" github.ruleset FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'next(r for r in d["rules"] if r["type"] == "required_status_checks")["parameters"]["required_status_checks"][0]["integration_id"] = 1'; expect "ci-gate pinned to the wrong app" github.ruleset FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'd["enforcement"] = "disabled"';   expect "ruleset disabled" github.ruleset FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'd["bypass_actors"] = [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}]'; expect "a bypass actor (archery's shape)" github.ruleset.no-bypass FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_per_page_100_page_1 'd[0]["name"] = "Copilot review for default branch"'
out=$(verify); rc=$?
if [ "$rc" -eq 1 ] && [ "$(result_of "$out" github.ruleset)" = FAIL ] && [ "$(result_of "$out" github.ruleset.no-bypass)" = FAIL ]; then
  ok "no ruleset named main: both ruleset rules FAIL"
else bad "no ruleset named main: both ruleset rules FAIL" "exit $rc — $(flat "$out")"; fi
fresh; gh_edit repos_blamechris_soundbed_issues_labels_epic_state_all_per_page_100_page_1 'd[:] = []'; expect "no genesis epic" github.epic FAIL 1

echo "== modules and overlay"
fresh; gh_edit repos_blamechris_soundbed_actions_runners_per_page_100_page_1 'd["runners"] = []; d["total_count"] = 0'; expect "no runner registered" module.runner-mac FAIL 1
fresh; edit .mcp.json 's.replace("@blamechris/repo-memory", "@someone/else")';        expect ".mcp.json without repo-memory" module.repo-memory FAIL 1
fresh; edit .github/workflows/repo-relay.yml 're.sub(r"blamechris/repo-relay@[0-9a-f]{40}", "blamechris/repo-relay@v1", s)'; expect "repo-relay pinned to a tag" module.repo-relay.workflow FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = [{"name": "DISCORD_BOT_TOKEN"}]'; expect "a relay secret not set, no human-setup issue" module.repo-relay.secrets FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = []'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 7, "title": "human-setup: relay", "body": "## Done when\n\nThe `genesis-verify` rule `module.repo-relay.secrets` reports PASS."}]'
expect "relay secrets pending with an open human-setup issue" module.repo-relay.secrets PENDING-HUMAN 0
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = []'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 8, "title": "human-setup: runner", "body": "rule `module.runner-mac`"}]'
expect "a human-setup issue for another rule does not excuse this one" module.repo-relay.secrets FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_runs_101_jobs_per_page_100_page_1 'next(j for j in d["jobs"] if j["name"] == "kotlin")["conclusion"] = "failure"'
expect "the kotlin job failed on the self-hosted runner, no human-setup issue" overlay.kotlin.android-sdk FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_runs_101_jobs_per_page_100_page_1 'next(j for j in d["jobs"] if j["name"] == "kotlin")["conclusion"] = "failure"'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 20, "title": "human-setup: Android SDK", "body": "## Done when\n\nThe `genesis-verify` rule `overlay.kotlin.android-sdk` reports PASS."}]'
expect "kotlin SDK failure pending with an open human-setup issue" overlay.kotlin.android-sdk PENDING-HUMAN 0
fresh; gh_edit repos_blamechris_soundbed_actions_runs_101_jobs_per_page_100_page_1 'next(j for j in d["jobs"] if j["name"] == "kotlin")["conclusion"] = "failure"'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 21, "title": "human-setup: relay", "body": "rule `module.repo-relay.secrets`"}]'
expect "a human-setup issue for a different rule does not excuse the Android SDK rule" overlay.kotlin.android-sdk FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_runs_101_jobs_per_page_100_page_1 'next(j for j in d["jobs"] if j["name"] == "kotlin")["labels"] = ["ubuntu-latest"]'
expect "kotlin green only on a hosted runner proves nothing about the runner host" overlay.kotlin.android-sdk FAIL 1
fresh
gh_edit repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20 'd["workflow_runs"].insert(0, {"id": 102, "head_sha": "b" * 40}); d["total_count"] = 2'
python3 -c 'import json,sys; json.dump({"total_count": 3, "jobs": [
    {"name": "route", "conclusion": "success", "labels": ["self-hosted", "macOS", "ARM64"]},
    {"name": "kotlin", "conclusion": "skipped", "labels": ["self-hosted", "macOS", "ARM64"], "runner_name": "soundbed-mbp-arm64"},
    {"name": "ci-gate", "conclusion": "success"},
]}, open(sys.argv[1], "w"))' "$MG/repos_blamechris_soundbed_actions_runs_102_jobs_per_page_100_page_1.json"
expect "the newest run's kotlin job skipped; an older run's success still counts" overlay.kotlin.android-sdk PASS 0
fresh
gh_edit repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20 'd["workflow_runs"].insert(0, {"id": 102, "head_sha": "b" * 40}); d["total_count"] = 2'
python3 -c 'import json,sys; json.dump({"total_count": 3, "jobs": [
    {"name": "route", "conclusion": "success", "labels": ["self-hosted", "macOS", "ARM64"]},
    {"name": "kotlin", "conclusion": "failure", "labels": ["self-hosted", "macOS", "ARM64"], "runner_name": "soundbed-mbp-arm64"},
    {"name": "ci-gate", "conclusion": "success"},
]}, open(sys.argv[1], "w"))' "$MG/repos_blamechris_soundbed_actions_runs_102_jobs_per_page_100_page_1.json"
expect "the newest run's decisive result wins over an older success" overlay.kotlin.android-sdk FAIL 1
fresh; gh_edit repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20 'd["workflow_runs"] = []; d["total_count"] = 0'
expect "no completed ci.yml runs yet" overlay.kotlin.android-sdk FAIL 1
fresh; mv "$MG/repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20.json" \
          "$MG/repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20.404"
expect "GitHub has no ci.yml workflow" overlay.kotlin.android-sdk FAIL 1
fresh; rm "$MG/repos_blamechris_soundbed_actions_workflows_ci.yml_runs_branch_main_status_completed_per_page_20.json"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" overlay.kotlin.android-sdk)" = ERROR ]; then ok "an unreadable ci.yml runs list is ERROR, not a guessed FAIL"
else bad "an unreadable ci.yml runs list is ERROR, not a guessed FAIL" "exit $rc — $(flat "$out")"; fi
fresh; rm "$M/CREDITS.md";                                                           expect "CREDITS.md removed" module.credits.file FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- credits-paths: none", "- credits-paths: app/src/main/res/raw")'
mkdir -p "$M/app/src/main/res/raw" && printf 'x' > "$M/app/src/main/res/raw/rain.ogg"
expect "a bundled asset without a CREDITS.md row" module.credits.coverage FAIL 1
printf '| `app/src/main/res/raw/rain.ogg` | freesound #1 | CC0 | none |\n' >> "$M/CREDITS.md"
expect "the same asset once credited" module.credits.coverage PASS 0
fresh; mkdir -p "$M/app" && printf 'android {\n  defaultConfig {\n    applicationId = "com.blamechris.other"\n  }\n}\n' > "$M/app/build.gradle.kts"
expect "applicationId differs from the reserved app ID" overlay.kotlin.app-id FAIL 1
fresh; mkdir -p "$M/app" && printf 'android {\n  defaultConfig {\n    applicationId = "com.blamechris.soundbed"\n  }\n}\n' > "$M/app/build.gradle.kts"
expect "applicationId equals the reserved app ID" overlay.kotlin.app-id PASS 0

echo "== waivers"
fresh; edit .claude/skill-profile.md 's.replace("- waivers: none", "- waivers: core.gitattributes (docs/adr/0002-no-attributes.md)")'
edit .gitattributes 's.replace("*.bat text eol=crlf\n", "")'
expect "a waiver without its ADR is a FAIL" core.gitattributes FAIL 1
mkdir -p "$M/docs/adr" && printf '# ADR-0002\n\nNo line-ending rules here.\n' > "$M/docs/adr/0002-no-attributes.md"
expect "a waiver whose ADR never names the rule is a FAIL" core.gitattributes FAIL 1
printf '# ADR-0002\n\nWaives `core.gitattributes`: no line-ending rules here.\n' > "$M/docs/adr/0002-no-attributes.md"
expect "a waiver with an ADR that names the rule is WAIVED" core.gitattributes WAIVED 0
fresh; edit .claude/skill-profile.md 's.replace("- waivers: none", "- waivers: core.gitattributes (README.md)")'
edit .gitattributes 's.replace("*.bat text eol=crlf\n", "")'
expect "a waiver citing a file outside docs/adr/ is a FAIL" core.gitattributes FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- waivers: none", "- waivers: profile.genesis-intent (docs/adr/0001-project-genesis.md)")'
expect "the intent rule cannot be waived" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- waivers: none", "- waivers: core.gitatributes (docs/adr/0001-project-genesis.md)")'
expect "a waiver naming no probed rule is an intent problem" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- waivers: none", "- waivers: github.ruleset.no-bypass (docs/adr/0001-project-genesis.md)")'
expect "the no-bypass rule cannot be waived" github.ruleset.no-bypass FAIL 1

echo "== could not verify: exit 2, never 0 or 1"
fresh; mv "$MG/repos_blamechris_soundbed.json" "$MG/repos_blamechris_soundbed.401"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" github.merge-settings)" = ERROR ]; then ok "gh answering 401 is ERROR / exit 2"
else bad "gh answering 401 is ERROR / exit 2" "exit $rc — $(flat "$out")"; fi
fresh; rm "$MG/repos_blamechris_soundbed_rulesets_42.json"
out=$(verify); rc=$?
[ "$rc" -eq 2 ] && ok "a ruleset the API will not return is exit 2" || bad "a ruleset the API will not return is exit 2" "exit $rc — $(flat "$out")"
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = []'
rm "$MG/repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1.json"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" module.repo-relay.secrets)" = ERROR ]; then ok "an unreadable human-setup list is ERROR, not a guessed FAIL"
else bad "an unreadable human-setup list is ERROR, not a guessed FAIL" "exit $rc — $(flat "$out")"; fi
fresh
out=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" python3 "$SUT" --registry "$TMP/nope" --registry-ref HEAD --no-fetch --repo "$M" --ref HEAD --gh-repo blamechris/soundbed 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a missing registry is exit 2" || bad "a missing registry is exit 2" "exit $rc — $(flat "$out")"
out=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --registry-ref no-such-ref --repo "$M" --ref HEAD --gh-repo blamechris/soundbed 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a registry ref that does not resolve is exit 2" || bad "a registry ref that does not resolve is exit 2" "exit $rc — $(flat "$out")"
out=$(verify --ref no-such-ref); rc=$?
[ "$rc" -eq 2 ] && ok "a repo ref that does not resolve is exit 2" || bad "a repo ref that does not resolve is exit 2" "exit $rc — $(flat "$out")"
git clone -q "$REG" "$TMP/reg-clone" && git -C "$TMP/reg-clone" remote set-url origin "$TMP/vanished.git"
out=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" python3 "$SUT" --registry "$TMP/reg-clone" --registry-ref origin/HEAD --repo "$M" --ref HEAD --gh-repo blamechris/soundbed 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'fetch origin failed'; then ok "a failed registry fetch is exit 2 (hard precondition)"
else bad "a failed registry fetch is exit 2 (hard precondition)" "exit $rc — $(flat "$out")"; fi
out=$(cd "$M" && FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --repo "$M" --ref HEAD 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no --gh-repo and no github origin is exit 2" || bad "no --gh-repo and no github origin is exit 2" "exit $rc — $(flat "$out")"

echo "== core-only round trip (no overlays, no modules)"
V --plan --json --name plainrepo --modules runner-mac --date 2026-09-26 > "$TMP/plain.json" || bad "core-only plan renders"
P="$TMP/plain"; mkdir -p "$P" && git -C "$P" init -q
python3 - "$TMP/plain.json" "$P" "$PLAN" "$BASE" <<'PY'
import json, os, shutil, sys
plan, root, _, base = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
for f in plan["files"]:
    p = os.path.join(root, f["path"]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").write(f["content"])
prof = open(os.path.join(base, ".claude/skill-profile.md")).read()
prof = prof.split("## project-genesis Customizations")[0] + plan["profile"]["section"] + "\n"
os.makedirs(os.path.join(root, ".claude/commands"), exist_ok=True)
open(os.path.join(root, ".claude/skill-profile.md"), "w").write(prof)
shutil.copy(os.path.join(base, ".claude/skills.lock"), os.path.join(root, ".claude/skills.lock"))
for n in os.listdir(os.path.join(base, ".claude/commands")):
    shutil.copy(os.path.join(base, ".claude/commands", n), os.path.join(root, ".claude/commands", n))
PY
commit_all "$P" plain
PG="$TMP/plain-gh"; cp -R "$GHBASE" "$PG"
for f in "$PG"/repos_blamechris_soundbed*; do mv "$f" "${f/repos_blamechris_soundbed/repos_blamechris_plainrepo}"; done
out=$(FAKE_GH_DIR="$PG" PATH="$FAKEBIN:$PATH" V --repo "$P" --ref HEAD --gh-repo blamechris/plainrepo --json 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(result_of "$out" module.repo-relay.secrets)" = N-A ] && [ "$(result_of "$out" overlay.kotlin.ci)" = N-A ] \
   && [ "$(result_of "$out" overlay.kotlin.android-sdk)" = N-A ]; then
  ok "a core + runner repo verifies clean with every other layer rule N-A"
else bad "a core + runner repo verifies clean with every other layer rule N-A" "exit $rc — $(flat "$out")"; fi
if grep -q '^  changes:' "$P/.github/workflows/ci.yml" || ! grep -q 'needs: \[route, hygiene\]' "$P/.github/workflows/ci.yml"; then
  bad "a core-only ci.yml has no changes job and ci-gate needs [route, hygiene]"
else ok "a core-only ci.yml has no changes job and ci-gate needs [route, hygiene]"; fi

echo "== plan"
if grep -q '@@' "$PLAN"; then bad "the soundbed plan leaves no placeholder" "$(grep -o '@@[A-Z_]*@@' "$PLAN" | sort -u | tr '\n' ' ')"
else ok "the soundbed plan leaves no placeholder"; fi
plan_field() { python3 -c "import json,sys; p=json.load(open(sys.argv[1])); print($2)" "$1"; }
got=$(V --plan --json --name sound-bed --stack kotlin --modules runner-mac | python3 -c 'import json,sys; print(json.load(sys.stdin)["intent"]["app_id"])')
[ "$got" = com.blamechris.soundbed ] && ok "app ID derived with separators dropped (sound-bed -> com.blamechris.soundbed)" || bad "app ID derivation" "got $got"
got=$(V --plan --json --name plainrepo | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["intent"]["app_id"], ",".join(p["intent"]["modules"]))')
[ "$got" = "none runner-mac,repo-memory,repo-relay" ] && ok "no app overlay: app ID none; modules default to the ratified three" || bad "plan defaults" "got $got"
refuses() {  # <name> <args...>
  local name=$1; shift
  local out rc; out=$(V --plan "$@" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE'; then ok "$name"; else bad "$name" "exit $rc — $(flat "$out")"; fi
}
refuses "refuses an invalid app ID" --name soundbed --stack kotlin --app-id com.blamechris.sound-bed
refuses "refuses a derived app ID that starts with a digit" --name 9lives --stack kotlin
refuses "refuses a planned overlay" --name x --stack flutter
refuses "refuses a planned module" --name x --modules runner-mac,docs-site
refuses "refuses an unknown module" --name x --modules runner-mac,telepathy
refuses "refuses a public repo (the public bundle is planned)" --name x --visibility public
refuses "refuses a non-slug name" --name Sound_Bed
refuses "refuses a missing name" --stack kotlin
refuses "refuses a repeated module" --name x --modules runner-mac,credits,credits
refuses "refuses a module set without the only runner module (the scaffold PR could never merge)" --name x --modules repo-memory
rel=$(plan_field "$PLAN" '[i for i in p["issues"] if i["kind"]=="human-setup"][0]["body"]')
if printf '%s' "$rel" | grep -q 'already set in: `blamechris/chroxy`, `blamechris/archery-apprentice`' \
   && printf '%s' "$rel" | grep -q '`module.repo-relay.secrets`' && ! printf '%s' "$rel" | grep -qi 'token:'; then
  ok "the relay human-setup issue names reuse sources and its Done-when rule"
else bad "the relay human-setup issue names reuse sources and its Done-when rule" "$(flat "$rel")"; fi
got=$(V --plan --json --name x --relay-token-in none | python3 -c 'import json,sys; p=json.load(sys.stdin); print([i["body"] for i in p["issues"] if i["kind"]=="human-setup"][0])')
printf '%s' "$got" | grep -q 'create a bot' && ok "--relay-token-in none says create a bot" || bad "--relay-token-in none says create a bot" "$(flat "$got")"
got=$(plan_field "$PLAN" '" ".join(d["decision"] for d in p["decisions"] if d["defaulted"])')
[ "$got" = "Visibility Self-merge posture Description" ] && ok "the Decisions table marks exactly the defaulted choices" || bad "the Decisions table marks exactly the defaulted choices" "got: $got"
got=$(plan_field "$PLAN" '"|".join(i["title"] for i in p["issues"])')
[ "$got" = "Land docs/design/SPEC.md|Credits reachable in-app for every bundled asset|human-setup: repo-relay Discord bot token and channel for blamechris/soundbed|human-setup: Android SDK on the runner host for blamechris/soundbed" ] \
  && ok "issues: SPEC always, credits with the module, one human-setup per manual step" || bad "plan issues" "$got"
sdk_body=$(plan_field "$PLAN" '[i for i in p["issues"] if i.get("rule") == "overlay.kotlin.android-sdk"][0]["body"]')
if printf '%s' "$sdk_body" | grep -qF '`overlay.kotlin.android-sdk`' \
   && printf '%s' "$sdk_body" | grep -qF '~/github-runners/actions-runner-soundbed/.env' \
   && ! printf '%s' "$sdk_body" | grep -q '@@'; then
  ok "the Android SDK human-setup body names its Done-when rule and the runner .env path, with no placeholder"
else
  bad "the Android SDK human-setup body names its Done-when rule and the runner .env path, with no placeholder" "$(flat "$sdk_body")"
fi
got=$(V --plan --json --name plainrepo --modules runner-mac --date 2026-09-26 | python3 -c \
  'import json,sys; p=json.load(sys.stdin); print(any("Android SDK" in i["title"] for i in p["issues"]))')
[ "$got" = "False" ] && ok "a plan with no kotlin overlay files no Android SDK human-setup issue" \
  || bad "a plan with no kotlin overlay files no Android SDK human-setup issue" "got: $got"
if plan_field "$PLAN" '[f["path"] for f in p["files"]]' | grep -q 'skill-profile'; then
  bad "the plan never renders the skill profile (Phase 4 composes it)"
else ok "the plan never renders the skill profile (Phase 4 composes it)"; fi
: > "$MG/calls.log"
FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --plan --json --name soundbed --stack kotlin >/dev/null 2>&1
[ -s "$MG/calls.log" ] && bad "--plan never calls GitHub" "$(head -2 "$MG/calls.log")" || ok "--plan never calls GitHub"

echo "== seed issues"
SEED="$TMP/seed.md"
cat > "$SEED" <<'SEEDEOF'
Label: area:core | 1d76db | The shared KMP core module
Label: area:playback | #0E8A16 | Media3 playback service

# Epic 0: M1 coexistence experiment
Labels: epic
Acceptance: Tests A/B/C have run across the §4 matrix
Acceptance: ADR-0003 records the M1 verdict

Tests A/B/C per §4; exits on the matrix plus the ADR-0003 verdict.

# Scaffold `:app` on AGP 9
Labels: enhancement, complexity:medium, area:core
Parent: Epic 0: M1 coexistence experiment
Acceptance: `:app` builds on AGP 9

Body. `##` headings are allowed here now.

## Notes

Some notes here.

```bash
# a comment inside a fence is not an entry
```

# human-setup: Android SDK on the runner Mac
Labels: human-setup

## What

Install the SDK.

## Why a human

Only a human can accept the license.

## Exact steps

1. Download it.

## Secret names

None.

## Reuse or create

N/A.

## Done when

The SDK is installed.
SEEDEOF

SEEDPLAN="$TMP/seed-plan.json"
: > "$MG/calls.log"
if FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --plan --json --name soundbed --stack kotlin --modules runner-mac \
  --app-id com.blamechris.soundbed --seed-issues "$SEED" --date 2026-09-26 > "$SEEDPLAN" 2>"$TMP/seed-plan.err"; then
  ok "a well-formed seed-issues file renders exit 0"
else bad "a well-formed seed-issues file renders exit 0" "$(flat "$(cat "$TMP/seed-plan.err")")"; fi

check=$(python3 - "$SEEDPLAN" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
si = p["seed_issues"]
problems = []
if len(si) != 3:
    problems.append(f"expected 3 seed issues, got {len(si)}")
else:
    if [e["kind"] for e in si] != ["work", "work", "human-setup"]:
        problems.append(f"kinds {[e['kind'] for e in si]}")
    if si[0]["labels"] != ["epic"] or si[0]["parent"] is not None:
        problems.append(f"epic entry {si[0]['labels']} parent={si[0]['parent']}")
    if si[1]["labels"] != ["enhancement", "complexity:medium", "area:core"]:
        problems.append(f"child labels {si[1]['labels']}")
    if si[1]["parent"] != "Epic 0: M1 coexistence experiment":
        problems.append(f"child parent {si[1]['parent']}")
    if si[2]["labels"] != ["human-setup"] or si[2]["parent"] is not None:
        problems.append(f"human-setup entry {si[2]['labels']} parent={si[2]['parent']}")
print("OK" if not problems else "FAIL: " + "; ".join(problems))
PY
)
[ "$check" = OK ] && ok "plan.seed_issues has 3 entries with the right kinds, labels and parents" \
  || bad "plan.seed_issues has 3 entries with the right kinds, labels and parents" "$check"

check=$(python3 - "$SEEDPLAN" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
body = p["seed_issues"][1]["body"]
problems = []
if not body.startswith("## Description"):
    problems.append("does not start with ## Description")
if not body.rstrip().splitlines()[-1].startswith("- [ ] "):
    problems.append("does not end with - [ ] criteria")
if "# a comment inside a fence is not an entry" not in body:
    problems.append("the fenced line is missing from the body")
print("OK" if not problems else "FAIL: " + "; ".join(problems))
PY
)
[ "$check" = OK ] && ok "the child's body starts \`## Description\`, ends with acceptance criteria, and keeps the fenced \`# not a title\` line" \
  || bad "the child's body starts with Description and ends with acceptance criteria" "$check"

check=$(python3 - "$SEEDPLAN" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1]))
body = p["seed_issues"][2]["body"]
got = re.findall(r"^## (.+)$", body, re.M)
want = ["What", "Why a human", "Exact steps", "Secret names", "Reuse or create", "Done when"]
print("OK" if got == want and "Filed from" not in body else f"FAIL: headings {got}")
PY
)
[ "$check" = OK ] && ok "the human-setup body is verbatim" || bad "the human-setup body is verbatim" "$check"

check=$(python3 - "$SEEDPLAN" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
labels, tail = p["github"]["labels"], p["github"]["labels"][-2:]
problems = []
if [l["name"] for l in tail] != ["area:core", "area:playback"]:
    problems.append(f"tail names {[l['name'] for l in tail]}")
if [l["color"] for l in tail] != ["1d76db", "0e8a16"]:
    problems.append(f"tail colours {[l['color'] for l in tail]}")
if p["github"]["owner_labels"] != ["area:core", "area:playback"]:
    problems.append(f"owner_labels {p['github']['owner_labels']}")
if not {"area:core", "area:playback"} <= set(p["profile"]["labels"]):
    problems.append("profile.labels is missing an owner label")
print("OK" if not problems else "FAIL: " + "; ".join(problems))
PY
)
[ "$check" = OK ] && ok "github.labels ends with the owner labels (colour normalised), owner_labels lists them, profile.labels includes them" \
  || bad "github.labels/owner_labels/profile.labels carry the owner labels" "$check"

want_sha=$(shasum -a 256 "$SEED" | awk '{print $1}')
got_sha=$(plan_field "$SEEDPLAN" 'p["intent"]["seed_issues"]["sha256"]')
got_path=$(plan_field "$SEEDPLAN" 'p["intent"]["seed_issues"]["path"]')
if [ "$got_sha" = "$want_sha" ] && [ "${got_path#/}" != "$got_path" ]; then
  ok "intent.seed_issues.sha256 matches shasum -a 256 of the file; path is absolute"
else
  bad "intent.seed_issues.sha256 matches shasum -a 256 of the file; path is absolute" "sha $got_sha want $want_sha; path $got_path"
fi

text=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --plan --name soundbed --stack kotlin --modules runner-mac \
  --app-id com.blamechris.soundbed --seed-issues "$SEED" --date 2026-09-26 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$text" | grep -qF 'Epic 0: M1 coexistence experiment' \
   && printf '%s' "$text" | grep -qF 'Scaffold `:app` on AGP 9' \
   && printf '%s' "$text" | grep -qF 'human-setup: Android SDK on the runner Mac' \
   && printf '%s' "$text" | grep -q '^Seed issues: ' \
   && printf '%s' "$text" | grep -q 'owner: area:core, area:playback'; then
  ok "text-mode --plan prints each seed title, the Seed issues line, and owner labels in the labels row"
else
  bad "text-mode --plan prints each seed title, the Seed issues line, and owner labels in the labels row" "exit $rc — $(flat "$text")"
fi

P2="$TMP/seed-plan2.json"
FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --plan --json --name soundbed --stack kotlin --modules runner-mac \
  --app-id com.blamechris.soundbed --seed-issues "$SEED" --date 2026-09-26 > "$P2" 2>/dev/null
if cmp -s "$SEEDPLAN" "$P2"; then ok "two --json renders with identical args are byte-identical"
else bad "two --json renders with identical args are byte-identical" "cmp differs"; fi

got=$(V --plan --json --name plainrepo --modules runner-mac --date 2026-09-26 | python3 -c \
  'import json,sys; p=json.load(sys.stdin); print(p["intent"]["seed_issues"], p["seed_issues"], p["github"]["owner_labels"])')
[ "$got" = "None [] []" ] && ok "without --seed-issues: intent.seed_issues is null, seed_issues is [], owner_labels is []" \
  || bad "without --seed-issues: intent.seed_issues is null, seed_issues is [], owner_labels is []" "got: $got"

got=$(V --plan --json --name plainrepo --modules runner-mac --date 2026-09-26 | python3 -c \
  'import json,sys; p=json.load(sys.stdin); print(p["machine"][0]["command"]); print("accessibility" in p["github"]["remove_default_labels"])')
[ "$got" = "$(printf '%s\n%s' '~/github-runners/provision-runner.sh plainrepo --host "${RUNNER_HOST:?}"' True)" ] \
  && ok "the runner step passes --host from a guarded RUNNER_HOST, and accessibility is a default to delete (#323)" \
  || bad "the runner step passes --host from a guarded RUNNER_HOST, and accessibility is a default to delete (#323)" "got: $(flat "$got")"

: > "$MG/calls.log"
FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --plan --json --name soundbed --stack kotlin --seed-issues "$SEED" >/dev/null 2>&1
[ -s "$MG/calls.log" ] && bad "--plan with --seed-issues never calls GitHub" "$(head -2 "$MG/calls.log")" \
  || ok "--plan with --seed-issues never calls GitHub"

seed_refuses() {  # <name> <needle> <seed-file>
  local name=$1 needle=$2 file=$3 out rc
  out=$(V --plan --name x --seed-issues "$file" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- "$needle"; then ok "$name"; else bad "$name" "exit $rc — $(flat "$out")"; fi
}

seed_refuses "a missing seed-issues file" "cannot read" "$TMP/seed-nope.md"

cat > "$TMP/seed-old.md" <<'SEEDEOF'
## Old style title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "an old-format file (## title entries)" "an issue starts with" "$TMP/seed-old.md"

cat > "$TMP/seed-strayp.md" <<'SEEDEOF'
not a label line

# Title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "stray preamble text" "the preamble holds only" "$TMP/seed-strayp.md"

cat > "$TMP/seed-unklabel.md" <<'SEEDEOF'
# Title
Labels: made-up-label
Acceptance: x

Body.
SEEDEOF
seed_refuses "a label not declared anywhere" "unknown label" "$TMP/seed-unklabel.md"

cat > "$TMP/seed-redefine.md" <<'SEEDEOF'
Label: bug | ffffff | redefine

# Title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "an undeclared owner label redefining bug" "redefines a standard label" "$TMP/seed-redefine.md"

cat > "$TMP/seed-defaultlabel.md" <<'SEEDEOF'
Label: question | ffffff | not allowed

# Title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "an owner label named after a default genesis deletes" "is a GitHub default genesis deletes" "$TMP/seed-defaultlabel.md"

cat > "$TMP/seed-badcolor.md" <<'SEEDEOF'
Label: area:x | not-a-colour | desc

# Title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "a bad owner colour" "invalid colour" "$TMP/seed-badcolor.md"

cat > "$TMP/seed-dupowner.md" <<'SEEDEOF'
Label: area:x | ffffff | one
Label: Area:X | 000000 | two

# Title
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "a duplicate owner label (case-insensitive)" "declared more than once" "$TMP/seed-dupowner.md"

cat > "$TMP/seed-nolabels.md" <<'SEEDEOF'
# Title
Acceptance: x

Body.
SEEDEOF
seed_refuses "a missing Labels: line" "has no" "$TMP/seed-nolabels.md"

cat > "$TMP/seed-replabels.md" <<'SEEDEOF'
# Title
Labels: bug
Labels: enhancement
Acceptance: x

Body.
SEEDEOF
seed_refuses "a repeated Labels: line" "repeats" "$TMP/seed-replabels.md"

cat > "$TMP/seed-unkkey.md" <<'SEEDEOF'
# Title
Labels: bug
Foo: bar
Acceptance: x

Body.
SEEDEOF
seed_refuses "an unknown header key" "invalid line" "$TMP/seed-unkkey.md"

cat > "$TMP/seed-emptybody.md" <<'SEEDEOF'
# Title
Labels: bug
Acceptance: x

SEEDEOF
seed_refuses "an empty body" "empty body" "$TMP/seed-emptybody.md"

cat > "$TMP/seed-noaccept.md" <<'SEEDEOF'
# Title
Labels: bug

Body.
SEEDEOF
seed_refuses "a work entry without Acceptance:" "requires acceptance criteria" "$TMP/seed-noaccept.md"

cat > "$TMP/seed-forbidden.md" <<'SEEDEOF'
# Title
Labels: bug
Acceptance: x

## Acceptance Criteria

Body.
SEEDEOF
seed_refuses "a work body with ## Acceptance Criteria" "must not contain heading" "$TMP/seed-forbidden.md"

cat > "$TMP/seed-hsaccept.md" <<'SEEDEOF'
# Title
Labels: human-setup
Acceptance: x

## What
## Why a human
## Exact steps
## Secret names
## Reuse or create
## Done when
SEEDEOF
seed_refuses "a human-setup entry with Acceptance:" "states its criteria under" "$TMP/seed-hsaccept.md"

cat > "$TMP/seed-hsmissing.md" <<'SEEDEOF'
# Title
Labels: human-setup

## What
## Why a human
## Exact steps
## Secret names
## Reuse or create
SEEDEOF
seed_refuses "a human-setup entry missing ## Done when" "missing" "$TMP/seed-hsmissing.md"

cat > "$TMP/seed-hsorder.md" <<'SEEDEOF'
# Title
Labels: human-setup

## What
## Exact steps
## Why a human
## Secret names
## Reuse or create
## Done when
SEEDEOF
seed_refuses "human-setup sections out of order" "out of order" "$TMP/seed-hsorder.md"

# A `~~~` fence masks headings exactly as a ``` fence does (PR #325 review): a `## Done when`
# that exists only inside one is not a section, and a reserved heading inside one is body text.
cat > "$TMP/seed-hstilde.md" <<'SEEDEOF'
# Title
Labels: human-setup

## What
## Why a human
## Exact steps
## Secret names
## Reuse or create
~~~
## Done when
~~~
SEEDEOF
seed_refuses "a human-setup ## Done when only inside a ~~~ fence is missing" "missing" "$TMP/seed-hstilde.md"

cat > "$TMP/seed-worktilde.md" <<'SEEDEOF'
# Title
Labels: enhancement
Acceptance: x

An example issue body, quoted:

~~~markdown
## Acceptance Criteria
~~~
SEEDEOF
if V --plan --json --name x --seed-issues "$TMP/seed-worktilde.md" >/dev/null 2>&1; then
  ok "a reserved heading inside a ~~~ fence is body text, not a refusal"
else bad "a reserved heading inside a ~~~ fence is body text, not a refusal"; fi

# Silent-loss shapes (PR #325 review): each would drop an entry or a `Parent:` without a word.
printf '# Parent epic\nLabels: epic\nAcceptance: done\n\nParent body.\n\n# Child\nLabels: bug\nAcceptance: works\n   \nParent: Parent epic\n\nChild body.\n' \
  > "$TMP/seed-splithdr.md"
seed_refuses "a header line below a whitespace-only line" "sits below a blank line" "$TMP/seed-splithdr.md"
printf '# First\nLabels: bug\nAcceptance: x\n\n```bash\necho never closed\n\n# Second\nLabels: bug\nAcceptance: y\n\nSecond body.\n' \
  > "$TMP/seed-openfence.md"
seed_refuses "an unclosed fence that would swallow the next entry" "never closes" "$TMP/seed-openfence.md"
printf '# Title\nLabels: enhancement\nAcceptance: x\n\n```markdown\n~~~\n# not a title\n## Context\n~~~\n```\n' \
  > "$TMP/seed-nested.md"
if V --plan --json --name x --seed-issues "$TMP/seed-nested.md" 2>/dev/null \
    | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if len(p["seed_issues"]) == 1 and "# not a title" in p["seed_issues"][0]["body"] else 1)'; then
  ok "a ~~~ inside a \`\`\` fence is content: one entry, the fenced # line kept, the fenced ## Context allowed"
else bad "a ~~~ inside a \`\`\` fence is content"; fi

printf '# Title\nLabels: enhancement\nAcceptance: x\n\n````markdown\n```bash\n# not a title\n## Acceptance Criteria\n```\n````\n\nTrailing prose.\n' \
  > "$TMP/seed-longfence.md"
if V --plan --json --name x --seed-issues "$TMP/seed-longfence.md" 2>/dev/null \
    | python3 -c 'import json,sys; p=json.load(sys.stdin); b=p["seed_issues"][0]["body"]; sys.exit(0 if len(p["seed_issues"]) == 1 and "# not a title" in b and "Trailing prose." in b else 1)'; then
  ok "a \`\`\`\` fence quoting a \`\`\` example closes only on \`\`\`\`: one entry, nothing refused"
else bad "a \`\`\`\` fence quoting a \`\`\` example closes only on \`\`\`\`"; fi

printf '# First\nLabels: bug\nAcceptance: x\n\n``` shown as `inline` code, not a fence\n\n# Second\nLabels: bug\nAcceptance: y\n\n```\nreal fence\n```\n' \
  > "$TMP/seed-inlineticks.md"
if V --plan --json --name x --seed-issues "$TMP/seed-inlineticks.md" 2>/dev/null \
    | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if [e["title"] for e in p["seed_issues"]] == ["First", "Second"] else 1)'; then
  ok "a backtick run with a backtick in its info string is inline code, not a fence that swallows the next entry"
else bad "a backtick run with a backtick in its info string is inline code, not a fence"; fi

out=$(V --repo "$M" --seed-issues "$SEED" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- "--seed-issues is a --plan flag"; then
  ok "--seed-issues outside --plan is refused, not silently ignored"
else bad "--seed-issues outside --plan is refused, not silently ignored" "exit $rc — $(flat "$out")"; fi

cat > "$TMP/seed-laterparent.md" <<'SEEDEOF'
# A
Labels: bug
Parent: B
Acceptance: x

Body.

# B
Labels: bug
Acceptance: y

Body.
SEEDEOF
seed_refuses "Parent: naming a later entry" "not an earlier entry" "$TMP/seed-laterparent.md"

cat > "$TMP/seed-unkparent.md" <<'SEEDEOF'
# A
Labels: bug
Parent: NoSuchThing
Acceptance: x

Body.
SEEDEOF
seed_refuses "Parent: naming an unknown title" "not an earlier entry" "$TMP/seed-unkparent.md"

cat > "$TMP/seed-duptitle.md" <<'SEEDEOF'
# A
Labels: bug
Acceptance: x

Body.

# A
Labels: bug
Acceptance: y

Body2.
SEEDEOF
seed_refuses "duplicate titles" "more than one entry" "$TMP/seed-duptitle.md"

cat > "$TMP/seed-spectitle.md" <<'SEEDEOF'
# Land docs/design/SPEC.md
Labels: bug
Acceptance: x

Body.
SEEDEOF
seed_refuses "a title equal to a title genesis already plans to file" "already plans to file" "$TMP/seed-spectitle.md"

printf '' > "$TMP/seed-empty.md"
seed_refuses "an empty file (no entries, no owner labels)" "empty" "$TMP/seed-empty.md"

echo "== self-check (the registry's rule<->probe parity gate)"
out=$(V --self-check 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "self-check passes on this tree's assets" || bad "self-check passes on this tree's assets" "$(flat "$out")"
SC="$TMP/sc"
sc_case() {  # <name> <needle> <python statement mutating files under $SC>
  local name=$1 needle=$2 prog=$3 out rc
  rm -rf "$SC"; cp -R "$REG" "$SC"
  (cd "$SC" && python3 -c "import json, os, re
$prog") || { bad "$name" "mutation failed"; return; }
  commit_all "$SC" mutant >/dev/null
  out=$(python3 "$SUT" --registry "$SC" --registry-ref HEAD --no-fetch --self-check 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "$needle"; then ok "$name"; else bad "$name" "exit $rc — $(flat "$out")"; fi
}
MAN=assets/genesis/standard-v1.json
LOADM="m = json.load(open('$MAN'))"
SAVEM="json.dump(m, open('$MAN', 'w'), indent=2)"
sc_case "a probe-class rule with no probe" "has no probe" "$LOADM
m['rules'].append({'id': 'core.invented', 'layer': 'core', 'class': 'probe', 'summary': 'x'})
$SAVEM"
sc_case "a probe with no rule" "has no rule in the manifest" "$LOADM
m['rules'] = [r for r in m['rules'] if r['id'] != 'core.pr-template']
$SAVEM"
sc_case "an advisory rule that has a probe" "classed advisory but has a probe" "$LOADM
next(r for r in m['rules'] if r['id'] == 'core.readme')['class'] = 'advisory'
$SAVEM"
sc_case "a duplicated rule id" "appears more than once" "$LOADM
m['rules'].append(dict(m['rules'][0]))
$SAVEM"
sc_case "an orphan template" "referenced by nothing" "open('assets/genesis/templates/core/orphan.md.tmpl', 'w').write('x')"
sc_case "a referenced template that is missing" "which does not exist" "os.remove('assets/genesis/templates/core/NON-GOALS.md.tmpl')"
sc_case "a template without the .tmpl suffix" "lacks the .tmpl suffix" "$LOADM
os.rename('assets/genesis/templates/core/gitignore.tmpl', 'assets/genesis/templates/core/.gitignore')
next(f for f in m['core']['files'] if f['path'] == '.gitignore')['template'] = 'templates/core/.gitignore'
$SAVEM"
sc_case "an undeclared placeholder" "undeclared placeholder @@INVENTED@@" "p = 'assets/genesis/templates/core/README.md.tmpl'
open(p, 'a').write('@@INVENTED@@\n')"
sc_case "an action pinned to a tag in a template" "not pinned to a full SHA" "p = 'assets/genesis/templates/core/ci.yml.tmpl'
s = open(p).read(); open(p, 'w').write(s.replace('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', 'actions/checkout@v7', 1))"
sc_case "a ruleset document with a bypass actor" "has bypass actors" "p = 'assets/genesis/ruleset-main.json'
d = json.load(open(p)); d['bypass_actors'] = [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}]
json.dump(d, open(p, 'w'))"
sc_case "a ruleset requiring more than ci-gate" "want exactly \['ci-gate'\]" "p = 'assets/genesis/ruleset-main.json'
d = json.load(open(p)); next(r for r in d['rules'] if r['type'] == 'required_status_checks')['parameters']['required_status_checks'].append({'context': 'lint', 'integration_id': 15368})
json.dump(d, open(p, 'w'))"
sc_case "a repeated seed label" "repeats" "p = 'assets/genesis/labels.json'
d = json.load(open(p)); d.append(dict(d[0])); json.dump(d, open(p, 'w'))"
sc_case "a planned module that carries files" "planned module" "$LOADM
m['modules']['docs-site']['files'] = [{'template': 'templates/core/README.md.tmpl', 'path': 'X.md'}]
$SAVEM"
sc_case "a human-setup entry citing a non-human rule" "not marked human" "$LOADM
m['human_setup'][0]['rule'] = 'core.readme'
$SAVEM"
sc_case "a ci fragment whose job ci-gate does not need" "rendered ci.yml: ci-gate needs" "$LOADM
m['overlays']['kotlin']['ci_job'] = 'kotlin-renamed'
$SAVEM"
sc_case "a renamed section in the human-setup issue template" "differ from HUMAN_SETUP_SECTIONS" "p = 'assets/genesis/templates/core/issue-human_setup.md.tmpl'
s = open(p).read(); open(p, 'w').write(s.replace('## Done when', '## Done wrong'))"

echo "== branches the round trip cannot reach"
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = []'
edit CLAUDE.md 's.replace("## Git workflow\n", "")'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 9, "title": "human-setup: both", "body": "rules `module.repo-relay.secrets` and `core.claude-md`"}]'
snap; out=$(verify); rc=$?
if [ "$rc" -eq 1 ] && [ "$(result_of "$out" core.claude-md)" = FAIL ] && [ "$(result_of "$out" module.repo-relay.secrets)" = PENDING-HUMAN ]; then
  ok "a human-setup issue excuses only rules marked human (core.claude-md stays FAIL)"
else bad "a human-setup issue excuses only rules marked human (core.claude-md stays FAIL)" "exit $rc — $(flat "$out")"; fi
fresh; mv "$MG/repos_blamechris_soundbed_vulnerability-alerts.204" "$MG/repos_blamechris_soundbed_vulnerability-alerts.401"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" github.security)" = ERROR ]; then ok "a 401 where a 404 means 'off' is still ERROR / exit 2"
else bad "a 401 where a 404 means 'off' is still ERROR / exit 2" "exit $rc — $(flat "$out")"; fi
fresh; python3 - "$MG" <<'PY2'
import json, os, sys
d = sys.argv[1]; key = "repos_blamechris_soundbed_labels_per_page_100_page_{}.json"
seed = json.load(open(os.path.join(d, key.format(1))))
extra = [{"name": f"area:{i}", "color": "ededed"} for i in range(100 - len(seed) + 1)]
allof = extra + seed                      # the last seed labels land on page 2
json.dump(allof[:100], open(os.path.join(d, key.format(1)), "w"))
json.dump(allof[100:], open(os.path.join(d, key.format(2)), "w"))
PY2
expect "labels spread over two pages are all read" github.labels PASS 0
out=$(verify)
ev=$(python3 -c 'import json,sys; print(next(r["evidence"] for r in json.loads(sys.argv[1])["results"] if r["rule"] == "github.labels"))' "$out" 2>/dev/null)
case "$ev" in *"also present: area:0, area:1, area:10, "*"(+72 more)") ok "80 extra labels: the evidence names 8 and counts the rest" ;;
  *) bad "80 extra labels: the evidence names 8 and counts the rest" "$ev" ;; esac
rm "$MG/repos_blamechris_soundbed_labels_per_page_100_page_2.json"
out=$(verify); rc=$?
[ "$rc" -eq 2 ] && ok "a page the API will not return is exit 2, not a missing label" || bad "a page the API will not return is exit 2, not a missing label" "exit $rc — $(flat "$out")"
fresh; edit .github/workflows/ci.yml 're.sub(r"^on:\n(?:[ \t].*\n|\n)*", "on: [push, pull_request]\n\n", s, count=1, flags=re.M)'
expect "inline on: [push, pull_request] is not restricted to main" core.ci-triggers FAIL 1
fresh; edit .github/workflows/ci.yml '"\n".join((" " * (2 * (len(l) - len(l.lstrip(" "))))) + l.lstrip(" ") for l in s.split("\n"))'
snap; out=$(verify); rc=$?
if [ "$rc" -eq 0 ] && [ "$(result_of "$out" core.ci-gate)" = PASS ] && [ "$(result_of "$out" overlay.kotlin.ci)" = PASS ]; then
  ok "a 4-space-indented ci.yml parses the same job graph"
else bad "a 4-space-indented ci.yml parses the same job graph" "exit $rc — $(flat "$out")"; fi
blank=$(python3 -c 'import json,sys
bad = [f["path"] for p in sys.argv[1:] for f in json.load(open(p))["files"] if "\n\n\n" in f["content"] or f["content"].startswith("\n")]
print(" ".join(bad))' "$PLAN" "$TMP/plain.json")
[ -z "$blank" ] && ok "rendered files carry no blank-line scar where a placeholder rendered empty" || bad "rendered files carry no blank-line scar" "$blank"
out=$(V --list-rules 2>&1); rc=$?
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1] + "/assets/genesis/standard-v1.json"))["rules"]))' "$REG")
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c ' probe \| advisory ')" -eq "$n" ]; then ok "--list-rules text prints one row per rule ($n)"
else bad "--list-rules text prints one row per rule ($n)" "exit $rc — $(flat "$out")"; fi
out=$(V --plan --name soundbed --stack kotlin 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^## Genesis plan — blamechris/soundbed (Standard v1)' \
   && printf '%s' "$out" | grep -q '^### Decisions' && printf '%s' "$out" | grep -q '| App ID | com.blamechris.soundbed \*(default)\*'; then
  ok "--plan text prints the write table and the Decisions table"
else bad "--plan text prints the write table and the Decisions table" "exit $rc — $(flat "$out")"; fi

echo "== review-found defects stay fixed"
fresh; edit .claude/skill-profile.md 's.replace("- visibility: private", "- visibility: Private")'; expect "a mis-cased visibility is an intent FAIL, not a crash" profile.genesis-intent FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- visibility: private", "- visibility: public")'; expect "a public intent is refused while its bundle is planned" profile.genesis-intent FAIL 1
fresh; printf '[]\n' > "$M/.claude/settings.json";                              expect "settings.json that is not an object is a FAIL, not a crash" core.claude-settings FAIL 1
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'next(r for r in d["rules"] if r["type"] == "required_status_checks")["parameters"]["required_status_checks"].append({"context": "ci-gate"})'
expect "a required check with no integration_id is compared, not a crash" github.ruleset FAIL 1
fresh; printf '["not", "a", "repo"]\n' > "$MG/repos_blamechris_soundbed.json"
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then ok "an API shape a probe did not expect is ERROR / exit 2 with a report"
else bad "an API shape a probe did not expect is ERROR / exit 2 with a report" "exit $rc — $(flat "$out")"; fi
fresh; edit .claude/skill-profile.md 's.replace("- credits-paths: none", "- credits-paths: ./app/src/main/res/raw/")'
mkdir -p "$M/app/src/main/res/raw" && printf 'x' > "$M/app/src/main/res/raw/rain.ogg"
expect "a ./-prefixed credits path still finds the uncredited asset" module.credits.coverage FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- credits-paths: none", "- credits-paths: app/src/main/res/raws")'
mkdir -p "$M/app/src/main/res/raw" && printf 'x' > "$M/app/src/main/res/raw/rain.ogg"
expect "a credits path that matches nothing is a FAIL, never a vacuous PASS" module.credits.coverage FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("- credits-paths: none", "- credits-paths: app/src/main/res/raw/rain.ogg")'
mkdir -p "$M/app/src/main/res/raw" && printf 'x' > "$M/app/src/main/res/raw/rain.ogg"
expect "a credits path naming a single file is checked" module.credits.coverage FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("  push:\n    branches: [main]\n", "  push:\n    branches:\n      - main\n      - \"**\"\n")'
expect "a block-list push.branches that adds ** is not main-only" core.ci-triggers FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("  push:\n    branches: [main]\n", "  push:\n    branches:\n      - main\n")'
expect "a block-list push.branches of exactly main passes" core.ci-triggers PASS 0
fresh; gh_edit repos_blamechris_soundbed_rulesets_42 'd["conditions"]["ref_name"]["exclude"] = ["~DEFAULT_BRANCH"]'
expect "a ruleset that excludes the default branch" github.ruleset FAIL 1
fresh; gh_edit repos_blamechris_soundbed 'd["permissions"]["admin"] = False'
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" github.security)" = ERROR ]; then ok "a non-admin token cannot see Dependabot settings: ERROR, not 'off'"
else bad "a non-admin token cannot see Dependabot settings: ERROR, not 'off'" "exit $rc — $(flat "$out")"; fi
fresh; gh_edit repos_blamechris_soundbed 'del d["allow_squash_merge"]'
out=$(verify); rc=$?
if [ "$rc" -eq 2 ] && [ "$(result_of "$out" github.merge-settings)" = ERROR ]; then ok "a settings key the API withheld is ERROR, not a mismatch"
else bad "a settings key the API withheld is ERROR, not a mismatch" "exit $rc — $(flat "$out")"; fi
fresh; edit .github/workflows/ci.yml 's.replace("    if: always()\n", "    if: always() && github.event_name == \x27push\x27\n")'
expect "ci-gate that can be skipped on PRs" core.ci-gate FAIL 1
fresh; edit .github/workflows/ci.yml 're.sub(r"(  ci-gate:\n(?:.*\n)*?    steps:\n)(?:.*\n?)*", lambda m: m.group(1) + "      # fail on failure or cancelled\n      - run: echo ok\n", s, count=1)'
expect "ci-gate whose only mention of failure is a comment" core.ci-gate FAIL 1
fresh; edit .github/workflows/ci.yml 's.replace("  hygiene:\n", "  \"deploy\":\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo deploy\n\n  hygiene:\n")'
expect "a quoted job key ci-gate does not need" core.ci-gate FAIL 1
fresh; edit .github/dependabot.yml 's.replace("  - package-ecosystem: github-actions\n    directory: /\n", "  - directory: /\n    package-ecosystem: github-actions\n")'
expect "a dependabot entry written directory-first is still read" core.dependabot PASS 0
fresh; edit .github/dependabot.yml 's.replace("interval: weekly", "interval: daily", 1) + "  - directory: /web\n    package-ecosystem: npm\n    schedule:\n      interval: weekly\n    labels: [dependencies]\n"'
expect "a later entry cannot lend github-actions its weekly schedule" core.dependabot FAIL 1
fresh; edit .claude/skill-profile.md 's.replace("## merge Customizations\n", "## merge Customizations\n\n```bash\n# how we merge here\ngh pr merge\n```\n\n")'
expect "a fenced # comment does not end a profile section" profile.merge-strategy PASS 0
fresh; gh_edit repos_blamechris_soundbed_actions_secrets_per_page_100_page_1 'd["secrets"] = []'
gh_edit repos_blamechris_soundbed_issues_labels_human-setup_state_open_per_page_100_page_1 'd[:] = [{"number": 12, "title": "wip", "body": "`module.repo-relay.secrets`", "pull_request": {"url": "x"}}]'
expect "an open PR is not a human-setup issue" module.repo-relay.secrets FAIL 1
fresh
out=$(FAKE_GH_DIR="$MG" PATH="$FAKEBIN:$PATH" V --repo "$M/docs" --ref HEAD --gh-repo blamechris/soundbed --json 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--repo pointing at a subdirectory still reads the whole commit" || bad "--repo pointing at a subdirectory still reads the whole commit" "exit $rc — $(flat "$out")"

echo "== the CI scripts themselves (route, changes), run under node"
if ! command -v node >/dev/null 2>&1; then
  echo "  skip node is not installed; the route/changes scripts are not simulated here"
else
  python3 - "$PLAN" "$TMP" <<'PY'
import json, re, sys
ci = next(f["content"] for f in json.load(open(sys.argv[1]))["files"] if f["path"] == ".github/workflows/ci.yml")
lines = ci.splitlines()
def script(job):
    i = lines.index(f"  {job}:")
    j = next(k for k in range(i, len(lines)) if lines[k].strip() == "script: |")
    ind = len(lines[j]) - len(lines[j].lstrip()) + 2
    body = []
    for ln in lines[j + 1:]:
        if ln.strip() and len(ln) - len(ln.lstrip()) < ind:
            break
        body.append(ln[ind:])
    return "\n".join(body)
for job in ("route", "changes"):
    open(f"{sys.argv[2]}/{job}.js", "w").write(script(job))
PY
  cat > "$TMP/sim.js" <<'JS'
// Runs a github-script body with a mocked context/github/core; prints outputs + failure.
const fs = require('fs');
const [,, file, scenarioJson] = process.argv;
const sc = JSON.parse(scenarioJson);
const out = {}; let failed = null;
const core = { info() {}, setOutput(k, v) { out[k] = v; }, setFailed(m) { failed = m; } };
const exists = (path, ref) => (sc.tree[ref] || []).includes(path);
const github = {
  rest: {
    pulls: { listFiles: 'listFiles' },
    repos: {
      compareCommitsWithBasehead: async () => ({ data: { files: sc.files.map(filename => ({ filename })) } }),
      getContent: async ({ path, ref }) => { if (exists(path, ref)) return {}; const e = new Error('nf'); e.status = 404; throw e; },
    },
  },
  paginate: async () => sc.files.map(filename => ({ filename })),
};
const context = { repo: { owner: 'o', repo: 'r' }, payload: sc.payload, eventName: sc.event, sha: 'HEAD' };
Object.assign(process.env, sc.env || {});
const body = fs.readFileSync(file, 'utf8');
new Function('context', 'github', 'core', 'process', `return (async () => {${body}})()`)(context, github, core, process)
  .then(() => console.log(JSON.stringify({ out, failed })))
  .catch(e => console.log(JSON.stringify({ error: String(e) })));
JS
  sim() {  # <name> <job> <scenario json> <python assertion over r>
    local r; r=$(node "$TMP/sim.js" "$TMP/$2.js" "$3" 2>&1)
    if python3 -c "import json,sys; r=json.loads(sys.argv[1]); assert $4, r" "$r" 2>/dev/null; then ok "$1"; else bad "$1" "$(flat "$r")"; fi
  }
  PR='{"number":1,"title":"feat: x","head":{"sha":"H","repo":{"fork":false}},"base":{"sha":"B"}}'
  sim "route: a fork PR runs hosted" route '{"event":"pull_request","payload":{"pull_request":{"number":1,"title":"[macos] x","head":{"sha":"H","repo":{"fork":true}},"base":{"sha":"B"}}}}' 'r["out"]["runner"] == "[\"ubuntu-latest\"]"'
  sim "route: runner_mode beats the title tag" route "{\"event\":\"workflow_dispatch\",\"payload\":{\"head_commit\":{\"message\":\"[linux] x\"}},\"env\":{\"RUNNER_MODE\":\"windows\"}}" 'r["out"]["runner"] == "[\"self-hosted\",\"Windows\"]"'
  sim "route: a PR title tag routes the PR" route '{"event":"pull_request","payload":{"pull_request":{"number":1,"title":"[macos] fix","head":{"sha":"H","repo":{"fork":false}},"base":{"sha":"B"}}},"env":{"RUNNER_MODE":""}}' 'r["out"]["runner"] == "[\"self-hosted\",\"macOS\"]"'
  sim "route: [github] anywhere in a push message breaks glass" route '{"event":"push","payload":{"head_commit":{"message":"fix: x\n\n[github]"}},"env":{"RUNNER_MODE":""}}' 'r["out"]["runner"] == "[\"ubuntu-latest\"]"'
  sim "route: RUNNER_DEFAULT when nothing else applies" route "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"env\":{\"RUNNER_MODE\":\"\",\"RUNNER_DEFAULT\":\"[\\\"self-hosted\\\",\\\"Linux\\\"]\"}}" 'r["out"]["runner"] == "[\"self-hosted\",\"Linux\"]"'
  sim "route: the Mac fallback" route "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"env\":{\"RUNNER_MODE\":\"\",\"RUNNER_DEFAULT\":\"\"}}" 'r["out"]["runner"] == "[\"self-hosted\",\"macOS\",\"ARM64\"]"'
  sim "changes: a docs-only PR skips kotlin" changes "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"files\":[\"docs/a.md\",\"README.md\",\".claude/skill-profile.md\"],\"tree\":{\"H\":[\"gradlew\"],\"B\":[\"gradlew\"]}}" 'r["out"]["kotlin"] == "false" and not r["failed"]'
  sim "changes: spec/vectors (a file type nobody listed) runs kotlin" changes "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"files\":[\"spec/vectors/a.json\"],\"tree\":{\"H\":[\"gradlew\"],\"B\":[\"gradlew\"]}}" 'r["out"]["kotlin"] == "true"'
  sim "changes: no gradlew yet skips kotlin (no test target yet)" changes "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"files\":[\"app/src/Main.kt\"],\"tree\":{\"H\":[],\"B\":[]}}" 'r["out"]["kotlin"] == "false" and not r["failed"]'
  sim "changes: deleting gradlew fails instead of switching the gate off" changes "{\"event\":\"pull_request\",\"payload\":{\"pull_request\":$PR},\"files\":[\"gradlew\"],\"tree\":{\"H\":[],\"B\":[\"gradlew\"]}}" 'r["failed"] and "gradlew" in r["failed"]'
  sim "changes: a push with no base touches everything" changes '{"event":"push","payload":{"before":"0000000000000000000000000000000000000000","after":"H"},"files":[],"tree":{"HEAD":["gradlew"]}}' 'r["out"]["kotlin"] == "true"'
fi

echo "== every probed rule has a mutation that FAILs it"
probed=$(V --list-rules --json | python3 -c 'import json,sys; print(" ".join(r["id"] for r in json.load(sys.stdin) if r["class"]=="probe"))')
missing=""
for r in $probed; do case " $COVERED " in *" $r "*) ;; *) missing="$missing $r" ;; esac; done
[ -z "$missing" ] && ok "all $(echo $probed | wc -w | tr -d ' ') probed rules are covered by a FAIL mutation" || bad "probed rules without a FAIL mutation:$missing"

echo
echo "genesis-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
