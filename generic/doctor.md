# /doctor

Diagnose a broken local setup and propose the fix. Works through the layers that make a project runnable — runtime version, installed dependencies, native modules, build state, and the entrypoint actually starting — finds the first thing that's wrong, and explains the remedy before touching anything.

Use this when something won't start, a build fails mysteriously, or the environment drifted after a runtime upgrade or a fresh clone. For diagnosing a failed *CI* run, use `/fix-ci`. For dependency upkeep specifically, use `/deps`.

## Arguments

- `$ARGUMENTS` — optional. A symptom or area to focus on (e.g. "server won't start", "build", "tests"). With no argument, run the full top-to-bottom health sweep.

Examples:
```
/doctor
/doctor "the server exits immediately on launch"
/doctor build
```

## Instructions

Run the checks in order, **cheapest and most foundational first** — a failure low in the stack explains failures above it, so stop drilling once you find the root cause. Each check: state what you're verifying, run a read-only probe, report ✓ / ✗ with the evidence.

### 1. Runtime & toolchain

Confirm the runtime and tools are present and at versions this project supports.

{{CUSTOMIZE: the runtime(s) and version constraints this project requires and how to check them, e.g. "node --version (requires Node 20+; engines field in package.json)", plus any other required toolchain (package manager, compiler). Note known-bad versions if any.}}

### 2. Dependency installation integrity

Confirm dependencies are installed and consistent with the manifest/lockfile.

{{CUSTOMIZE: how to verify install integrity for this project, e.g. "node_modules present and consistent with package-lock.json (npm ls / npm ci --dry-run)". Note the symptom of a stale install.}}

### 3. Native modules load

Native/compiled dependencies are pinned to the runtime ABI and are the most common cause of "it installed but won't run" — especially after a runtime major-version change. Verify each native module actually loads under the current runtime, not just that it's present on disk.

{{CUSTOMIZE: this project's native/compiled dependencies and how to probe that each loads, e.g. "require('better-sqlite3') opens an in-memory db without an ABI error". Note the safe fix when a module fails to load (reinstall to fetch a matching prebuilt — NOT a from-source rebuild if source-compile is known to fail on the current runtime). If the project has no native deps, REMOVE THIS MARKER LINE and skip the step.}}

### 4. Build state

Confirm the project builds (or that a prior build artifact is current with its sources).

{{CUSTOMIZE: the build command and where its output lands, e.g. "npm run build → dist/; check dist is newer than src". Note whether the running entrypoint uses the build output or the sources directly.}}

### 5. Entrypoint / service starts

The decisive check: does the thing actually start and respond? Launch the entrypoint and confirm it reaches a ready state rather than crashing on boot.

{{CUSTOMIZE: how to start this project's primary entrypoint and what "healthy startup" looks like, e.g. for a server: bind to its port; for an MCP server: complete an initialize handshake over stdio; for a CLI: --version exits 0. Give the concrete start command and the success signal to look for.}}

### 6. Integration / configuration

Check the config and external wiring the project depends on to run in context.

{{CUSTOMIZE: project-specific config/integration checks, e.g. required env vars present, a config file points at the right entrypoint/build, an MCP client config launches the server correctly. Remove if the project has no external config to verify.}}

### 7. Diagnose & fix

From the first failing check, state the **root cause** (not just the symptom) and the remedy.

- For safe, read-only or clearly-reversible fixes (reinstall a dependency, rebuild), propose the exact command.
- Before any command that **deletes files, modifies global config, or changes the installation**, show what it does and get confirmation — do not run it unprompted.
- If a "fix" looks wrong for this setup (e.g. a from-source rebuild that's known to fail on the current runtime), say so and offer the correct alternative instead of running the obvious-but-wrong one.

### 8. Report

```markdown
## Doctor: <project>

| Check | Status |
|---|---|
| Runtime & toolchain | ✓ / ✗ <detail> |
| Dependencies installed | ✓ / ✗ |
| Native modules load | ✓ / ✗ |
| Build state | ✓ / ✗ |
| Entrypoint starts | ✓ / ✗ |
| Integration/config | ✓ / ✗ |

**Root cause:** <the first failure that explains the rest, or "none — environment healthy">
**Fix:** <exact remedy, or the command awaiting your confirmation>
```

If every check passes, say so plainly and note the most likely place to look next if the user is still seeing a problem.

## Customization Points

- **Runtime & toolchain** — required runtimes/tools, version constraints, known-bad versions.
- **Install integrity** — how to verify dependencies match the lockfile.
- **Native modules** — the project's native deps, how to probe each loads, and the safe fix; or none.
- **Build state** — the build command, output location, and whether the entrypoint runs the build or the sources.
- **Entrypoint startup** — the start command and the concrete "healthy" signal.
- **Integration/config** — env vars, config files, and external wiring to verify; or none.
