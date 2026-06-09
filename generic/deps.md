# /deps

Keep this project's dependencies healthy: report what's outdated and vulnerable, flag native modules that can break across runtime upgrades, and apply the safe bumps with tests as the gate. A periodic checkup that catches dependency rot before it becomes a broken build or a security advisory.

Use this before a `/release`, after a runtime (Node/Python/etc.) upgrade, or on a regular cadence. For diagnosing an *already* broken install, use `/doctor`.

## Arguments

- `$ARGUMENTS` — configuration. Space-separated tokens:
  - `--audit-only` — report health, propose nothing, change nothing (default is report + propose).
  - `--apply` — actually apply the safe (non-major) bumps and run the test gate after each batch.
  - `--include-major` — also surface and individually evaluate major (breaking) upgrades, not just safe ones.
  - First positional: optional scope filter (a package name or glob) to narrow the checkup.

Examples:
```
/deps                 # full checkup, propose safe bumps, change nothing
/deps --apply         # apply safe bumps, gated by tests
/deps --audit-only    # read-only health report
/deps --include-major # also evaluate breaking upgrades
```

## Instructions

### 1. Inventory outdated dependencies

List what has newer versions available and classify each by semver distance (patch / minor / major).

{{CUSTOMIZE: the command(s) that list outdated dependencies for this project's package manager, e.g. "npm outdated --json" / "pip list --outdated" / "cargo outdated". Note if the project has multiple manifests/workspaces to sweep.}}

### 2. Security audit

Surface known vulnerabilities in the current dependency tree, with severity.

{{CUSTOMIZE: the security-audit command, e.g. "npm audit --json" / "pip-audit" / "cargo audit". Note the project's policy on advisories (e.g. "high+ must be resolved before release").}}

### 3. Native / runtime-compatibility check

Native addons and compiled dependencies are pinned to the runtime's ABI and break when the runtime crosses a major version — a class of failure that a plain "outdated" check misses entirely. For each dependency with a native/compiled component:

- Identify whether a prebuilt binary exists for the **current** runtime version, or whether it must compile from source.
- Flag any that would fail to compile or load on the runtime in use (mismatched ABI / module version, missing prebuilt, dropped toolchain API).
- Note the safe remediation (reinstall to fetch a matching prebuilt, pin a runtime version, or upgrade the dependency to a release that ships prebuilts for the current runtime).

{{CUSTOMIZE: this project's native/compiled dependencies and any known runtime-compatibility constraints, e.g. "better-sqlite3 — prebuilt-only on Node 26, reinstall don't rebuild". If the project has no native dependencies, REMOVE THIS MARKER LINE and state that this step is a no-op for a pure-managed-language project.}}

### 4. Categorize and decide

Group findings into:

- **Safe** — patch/minor bumps within semver, no advisory, no native concern. Candidates for `--apply`.
- **Breaking** — major bumps, or any bump that crosses a documented breaking change. Evaluate individually (only when `--include-major`); each needs its own read of the upstream changelog.
- **Security-driven** — bumps required to clear an advisory, regardless of semver distance. Prioritize these.

### 5. Apply (only with `--apply`)

For `--apply`, update the safe bumps in batches and gate each batch on the test suite — never apply a wave of bumps without verifying:

{{CUSTOMIZE: the install + test commands used to apply and verify, e.g. "npm install" then "npm test" (and "npm run build" if the build can catch breakage the tests miss). Note any lockfile that must be committed.}}

If a batch fails the gate, bisect it: revert the batch, re-apply one dependency at a time, and isolate the offender. Report the offender rather than leaving the tree red.

Without `--apply`, change nothing — only propose the exact commands the user could run.

### 6. Report

```markdown
## Dependency Checkup: <project>

### Security  (N advisories)
| Package | Severity | Installed → Fixed | Action |
|---|---|---|---|

### Safe bumps  (N)
| Package | Current → Latest | Type |
|---|---|---|

### Breaking / needs review  (N)   ← only with --include-major
| Package | Current → Latest | Why it's breaking |
|---|---|---|

### Native / runtime compatibility
<findings from step 3, or "no native dependencies">

### Applied   ← only with --apply
<what was bumped, test result per batch, any offender isolated>
```

End with a one-line recommendation: the single highest-value next action (e.g. "Clear the 2 high-severity advisories before the next /release").

## Customization Points

- **Outdated command** — how this project lists outdated dependencies; multiple manifests/workspaces if any.
- **Audit command + policy** — the security-audit command and the project's advisory-severity policy.
- **Native dependencies** — the project's native/compiled deps and known runtime-compatibility constraints; or note that there are none.
- **Apply + test commands** — the install and test/build commands that apply and gate bumps, plus the lockfile to commit.
