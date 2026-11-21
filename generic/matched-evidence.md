# /matched-evidence

Report a game or interactive UI change with matched browser evidence: the agreed baseline and candidate are built from clean, recorded revisions, every agreed scenario is captured on both sides under identical conditions, and the report shows full-viewport stills, labelled recordings and a side-by-side GIF, with provenance, hashes and every gap stated. It uses the project's own build, fixture and test commands, and it reports. It never deploys, pushes or triggers CI.

## What this is not

- **Not an approval card** (`/look-approve`). That shows one ref to the owner and asks for a verdict. This compares two refs and asks nothing.
- **Not a smoke test** (`/smoke-form`). Nobody fills in pass/fail here.
- **Not a code review** (`/agent-review`). Nothing here judges the diff.
- **Not a pixel-diff gate.** It may report a pixel delta, but it never fails a build.

## Arguments

- `$ARGUMENTS` — the comparison, plus optional flags:
  - `--baseline REF` and `--candidate REF`. Both are required unless the task already names them, such as "PR #51 against main". If neither the task nor the owner gives them, ask once and stop. Never guess a baseline.
  - `--scenarios PATH`. A JSON file of agreed scenarios. Without it, write the list in step 1 and get it agreed first.
  - `--dir PATH`. The output directory, which overrides the default below.
  - `--no-open`. Write the report but do not open it.

## Output location

1. `--dir PATH` if given.
2. `$CLAUDE_BRIEF_DIR` if set.
3. Otherwise `~/.claude/briefs/`, created if missing.

```
<dir>/matched-evidence-<slug>-<YYYY-MM-DD>/
  index.html                                   ← the report
  provenance.json                              ← step 2 record, machine-readable
  SHA256SUMS                                   ← every file below
  specs/<scenario>.json                        ← the one spec both sides ran
  media/<scenario>/baseline-<short>/moment-<label>.png
  media/<scenario>/baseline-<short>/frames/f_NNNN.png
  media/<scenario>/baseline-<short>/recording.mp4
  media/<scenario>/candidate-<short>/…         ← same names, candidate side
  media/<scenario>/compare.gif
```

Never overwrite. Append `-2`, `-3` on collision. The report links its media by relative path, so the whole folder moves together. Say so when you give the path. Nothing here is written inside a repository working tree.

## Boundaries — read before anything runs

- **This workflow never deploys, never pushes, and never triggers CI.** No `git push`, no `gh workflow run`, no `gh pr` writes, no release, no preview deploy, no commit to either revision. If a build command would publish anything (an upload step, a postbuild deploy hook), stop and report it as a blocker rather than run it.
- **Isolated and bounded.** Each side runs from its own detached worktree, on its own port, in a fresh browser profile. Every build, server and capture runs under a hard timeout (`timeout -k 30 <s>`; `gtimeout` on stock macOS). Record each process ID you start, and stop exactly those PIDs. Never kill by name or pattern.
- **Project-approved tooling only.** Drive the browser with the automation the project already depends on (its lockfile pins it), and serve with the project's own command. Add no dependency to either revision. If the project has no approved browser automation, stop and name that as the blocker.
- **Capture the app surface only.** Screenshots and frames come from the automation's page capture, never from an OS screen recording or a desktop screenshot. The browser profile is fresh and signed out. Use fixture or seed data only, never a real account, real user data or a personal screen. If a scenario seems to need real data, label it a gap.

{{CUSTOMIZE: this repo's approved browser automation (package and version from the lockfile), how it is invoked, and any build step that must be skipped because it publishes}}

## Instructions

### 1. Agree the pair and the scenarios

Write the comparison down before you build anything:

- **Baseline** and **candidate**: the refs as agreed, and who or what agreed them (the task text, the PR, the owner's words).
- **Scenarios**: one row each, with an id, the route, the initial state, the input sequence, the matching moments to capture, and the **requested visible elements**, meaning what a reader should be able to see in each still. Those elements are what step 7 checks.

```json
{
  "id": "s01-wave-start",
  "route": "/play?fixture=wave-start",
  "viewport": { "width": 1280, "height": 720 },
  "deviceScaleFactor": 2,
  "colorScheme": "dark",
  "reducedMotion": "no-preference",
  "initialState": { "storage": "empty", "fixture": "wave-start", "seed": 4242 },
  "input": { "type": "mouse", "sequence": [ { "frame": 10, "op": "click", "target": "[data-testid=start]" } ] },
  "timing": { "clock": "project-fixture", "startEpochMs": 1767225600000, "stepMs": 50, "frames": 120 },
  "moments": [ { "label": "first-hit", "frame": 40 } ],
  "visible": [ "score counter, top right", "new enemy sprite at spawn" ]
}
```

The scenario list is what was agreed. Do not add a scenario because it photographs well, and do not drop one because the baseline makes it hard.

{{CUSTOMIZE: where agreed scenarios come from in this repo (an issue checklist, a test plan, a fixture directory) and the default viewport and pixel ratio for this product}}

### 2. Provenance, before the first capture

Create one detached worktree per side, from fetched refs:

```bash
REPO={{CUSTOMIZE: absolute path to this repo's working copy}}
RUN="$(mktemp -d)/matched-evidence-$(date -u +%Y%m%dT%H%M%SZ)"
git -C "$REPO" fetch origin
for SIDE in baseline candidate; do
  REF_VAR=$([ "$SIDE" = baseline ] && echo "$BASELINE_REF" || echo "$CANDIDATE_REF")
  git -C "$REPO" worktree add --detach "$RUN/$SIDE" "$REF_VAR"
done
```

Then record, per side, into `provenance.json`:

| Field | How |
|---|---|
| commit | `git -C "$RUN/$SIDE" rev-parse 'HEAD^{commit}'` (the full ID) |
| tree | `git -C "$RUN/$SIDE" rev-parse 'HEAD^{tree}'` |
| clean | `git -C "$RUN/$SIDE" status --porcelain --ignored=no` is empty **before the build**, and again after it apart from paths the build is documented to write |
| executables | the version of every tool the build and capture call: runtime, package manager, engine, browser binary, `ffmpeg` |
| lockfiles | the SHA-256 of each lockfile |
| assets | the SHA-256 of each served binary asset the scenarios touch, after confirming it is real content and not an LFS pointer (`file <asset>`) |
| build | each build and serve command, verbatim, with its exit code and duration |
| fixtures | each fixture, clock or test hook in use, and **every change it makes to served bytes** |

A dirty tree before the build is a stop, not a note. Report it and do not capture.

**Fixture changes to served bytes.** If a fixture injects a script, rewrites a built file or serves a different asset, the reader must be able to see exactly what was served. Record the SHA-256 of each changed served file as built and as served (fetch it from the running server), and say what changed. A fixture that changes served bytes on one side only makes that scenario unmatched. Label it in step 4.

```bash
python3 - "$URL" "$PATHS_FILE" <<'PY'
import hashlib, sys, urllib.request
base, listing = sys.argv[1], sys.argv[2]
for p in open(listing).read().split():
    body = urllib.request.urlopen(base.rstrip('/') + p, timeout=30).read()
    print(hashlib.sha256(body).hexdigest(), p)
PY
```

{{CUSTOMIZE: this repo's install, build and serve commands, the files the build legitimately writes, the binary assets to hash, and the fixture/clock/test hooks it provides}}

### 3. Check that the baseline can run each scenario

For every scenario, check in the **baseline source** that the route, the fixture and the controls the input sequence uses exist. Cite the file and line.

When the baseline lacks the feature a scenario needs, that pair is **unavailable**. Record it with the reason (for example "baseline has no `wave-start` fixture; added in the candidate at `src/fixtures/wave.ts:12`") and capture the candidate side alone, labelled *candidate only — no baseline pair*. Never stand in a nearby baseline screen. Do not stage substitute screenshots.

### 4. Capture both sides under one spec

Both sides run the **same spec file**, byte for byte, written once to `specs/<scenario>.json`. Only the base URL differs. That is the matching contract: viewport size, device pixel ratio, theme, initial state, route, input type and sequence, and timing are identical because they come from one file.

After load and before the first input, read the real values back on each side and record them. A mismatch is a gap, not a rounding error:

```js
await page.evaluate(() => ({
  w: innerWidth, h: innerHeight, dpr: devicePixelRatio,
  dark: matchMedia('(prefers-color-scheme: dark)').matches,
  url: location.pathname + location.search,
}));
```

**Timing.** Match moments by frame or by state, never by wall-clock sleep.

- If the project provides a clock or deterministic-state fixture, use it, say which, and cite its source. Step the clock by `stepMs` and capture one frame per step. Frames are then matched by construction, and none can drop.
- If it does not, and the approved automation has a clock (Playwright's `page.clock`, for example), check in source that it covers the app's actual timing source (`requestAnimationFrame`, `performance.now`, workers, audio time) before relying on it. Say what it does not cover.
- Without either, capture in real time. Record each frame's timestamp, the target rate and the dropped frames, and label the moments *approximately matched*.

**Server-authoritative state.** A browser clock does not control the server. When the server owns state:

- Retain the seed every side was given, and the server's own seed or config if it has one.
- At each matching moment, capture an **actual state digest** from the project's state endpoint or test hook, on both sides. Report both digests. Equal digests are how state equality is shown. If no hook exists, say that state equality was not verified.
- Connection-only counters (sequence numbers, ticks since connect, reconnect counts, session IDs) differ between runs by nature. Keep them in a separate column, and only after verifying in source what each one means (cite it). Exclude a counter whose meaning you did not verify, and never fold one into the digest.

**Show how equality was verified.** For each moment, the report shows the digest pair, or the frame index under the shared clock, and says *equal*, *differs* (with what) or *not verifiable* (with why).

**When the baseline cannot reproduce a scenario**, stop that scenario and label the gap: what was attempted, where it diverged (the frame, the digest, the missing element) and the evidence. Do not retry until it looks right, do not change the spec for one side, and do not stage substitute screenshots.

A driver sketch, shown for Playwright. Use the project's approved tool and its own fixture hooks:

```js
// capture.mjs <spec.json> <baseUrl> <outDir>
import { chromium } from '{{CUSTOMIZE: approved automation package}}';
import fs from 'node:fs';
const [specPath, baseUrl, out] = process.argv.slice(2);
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: spec.viewport, deviceScaleFactor: spec.deviceScaleFactor,
  colorScheme: spec.colorScheme, reducedMotion: spec.reducedMotion,
}); // a new context starts with empty storage; seed state only through the spec's fixture

const page = await ctx.newPage();
await page.clock.install({ time: spec.timing.startEpochMs }); // or the project's own clock fixture
await page.goto(baseUrl + spec.route);
fs.mkdirSync(`${out}/frames`, { recursive: true });
const log = { readback: await page.evaluate(() => ({ w: innerWidth, h: innerHeight, dpr: devicePixelRatio })), frames: [] };
for (let f = 0; f < spec.timing.frames; f++) {
  for (const step of spec.input.sequence.filter(s => s.frame === f)) await page.click(step.target);
  const name = `f_${String(f).padStart(4, '0')}.png`;
  await page.screenshot({ path: `${out}/frames/${name}`, fullPage: false, animations: 'allow', scale: 'device' });
  log.frames.push({ f, name, digest: await page.evaluate(() => window.{{CUSTOMIZE: state digest hook, or remove}}?.()) });
  await page.clock.runFor(spec.timing.stepMs);
}
fs.writeFileSync(`${out}/capture-log.json`, JSON.stringify(log, null, 2));
await browser.close();
```

Record the input type honestly. Automation clicks and key presses are **synthetic events**, not a finger, a gamepad or a real keyboard.

{{CUSTOMIZE: the state digest hook or endpoint, the connection-only counters and where their meaning is defined in source, and the clock or deterministic-state fixture this project provides}}

### 5. Produce the media

From the frames, per side and scenario:

- **Stills.** Each matching moment's frame, copied unedited to `moment-<label>.png`. These are full-viewport PNGs at viewport × pixel ratio, with no crop, scale, annotation or recompression. A still is the raw capture or it is not in the report.
- **Recordings.** One per side, encoded from that side's own frames and labelled by file name and by container title, never by drawing on the app's pixels:
  ```bash
  ffmpeg -v error -framerate "$FPS" -i "$SIDE_DIR/frames/f_%04d.png" \
    -metadata title="$SIDE $SHORT $SCENARIO" -c:v libx264 -pix_fmt yuv420p -crf 18 \
    "$SIDE_DIR/recording.mp4"
  ```
- **Side-by-side GIF.** Built from the two recorded frame sequences, not from the stills. Each label goes in a band added **outside** the app viewport (padding above the frame). The app pixels are never drawn on:
  ```bash
  L='pad=iw+8:ih+40:0:40:color=0x111111,drawtext=fontfile={{CUSTOMIZE: font path}}:fontcolor=white:fontsize=22:x=10:y=9:text'
  ffmpeg -v error -framerate "$FPS" -i "$B/frames/f_%04d.png" -framerate "$FPS" -i "$C/frames/f_%04d.png" \
    -filter_complex "[0]$L='BASELINE $B_SHORT'[a];[1]$L='CANDIDATE $C_SHORT'[b];[a][b]hstack=inputs=2,fps=$GIF_FPS,scale=$GIF_W:-1:flags=lanczos,split[s][t];[s]palettegen=stats_mode=diff[p];[t][p]paletteuse=dither=none" \
    "$SCEN_DIR/compare.gif"
  ```

Record every transform in `provenance.json` and on the report: capture step and playback rate (the **pacing**, such as "50 ms of app time per frame, played at 20 fps, so real time"), any scaling (the GIF's width against the native width), the encoding (codec, CRF, palette, dither) and the **dropped frames** (expected against recorded, with the indexes). Derived media (recordings and the GIF) are labelled *derived*. Stills are labelled *unedited capture*.

### 6. Hash everything

```bash
cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name index.html -print0 | sort -z \
  | xargs -0 shasum -a 256 > SHA256SUMS
```

The report shows each file's hash next to its download link, from this file.

### 7. Verify the media before you write a word about it

Each check is run, not assumed, and its result goes in the report:

- **Decodes.** `ffmpeg -v error -i <file> -f null -` exits 0 and prints nothing, for every PNG, MP4 and GIF.
- **Dimensions.** Each still is exactly viewport × pixel ratio (`ffprobe -v error -show_entries stream=width,height -of csv=p=0`). Each recording's frame count matches its frames directory.
- **Labelled correctly.** The side and short SHA in each file name and label match `provenance.json`, and the GIF's left panel is the baseline.
- **Hashes match.** `shasum -a 256 -c SHA256SUMS` passes after the report is written.
- **Requested elements are visible.** Open each still and look at it. For each element in the scenario's `visible` list, state *visible*, *not visible* or *unclear*. A DOM query that finds the element is a separate, weaker line ("in the DOM, 24×24 at 1210,18"). It is never the visual check.

A failed check is reported as failed. Re-capture only by rerunning the same spec on both sides, never by editing a file.

### 8. Classify every claim by evidence

Every statement the report makes carries one class:

| Class | What it is | What it can claim |
|---|---|---|
| **visual** | a captured still or frame, looked at | what was on screen in this browser at this size |
| **DOM** | a query, computed style or accessibility tree read | what the document contained, not what a person sees |
| **automated input** | synthetic events from the automation | that the app responded to scripted input, not to real hardware |
| **state** | digests or seeds from the project's hooks | that both sides reached the same or different state |
| **device** | a physical device, its input and its display | only what was actually run on one; usually nothing |

DOM observations and automated input are never presented as visual or device evidence. If no physical device was used, the device row says so.

### 9. Write the report

A self-contained HTML page (inline `<style>` and no external requests). It is dark by default with `:root{color-scheme:dark;…}`, a dark palette and `<meta name="color-scheme" content="dark">`, and has no `prefers-color-scheme` switch and no `light dark` value. Keep every colour behind a CSS variable.

Top to bottom:

1. **Result**: two or three sentences, the baseline and candidate commit pair, and one status chip per scenario (*matched*, *approximately matched*, *gap*, *unavailable*).
2. **Navigation**: a sticky table of contents linking each scenario's anchor, Provenance, Verification and Open items.
3. **One section per scenario**: the matched-parameter table with read-back values for both sides, the baseline and candidate stills side by side under each moment, both recordings as separate labelled `<video controls>` elements, the comparison GIF, the state-equality line, the requested-element checks with evidence classes, and any gap or unavailable reason in full.
4. **Provenance**: commits, trees, clean checks, executable versions, lockfile and asset hashes, build commands, fixture changes to served bytes, and media transforms (pacing, scaling, encoding, dropped frames).
5. **Downloads**: a link with the `download` attribute for every media file, `provenance.json` and `SHA256SUMS`, each with its hash.
6. **Verification**: the step 7 results, one row per file.
7. **Open items**: exactly what this report does not establish, always present. Name each check that was outside the requested scope or could not run. At minimum, address **physical devices**, **native fullscreen**, **accessibility** and **live integration** (real servers, real accounts, networked play). For each, say *not in scope*, *not run (why)* or *covered (where)*.
8. **Cleanup and blockers**: what was stopped and removed, what could not be, and every permission or tooling blocker hit.

```html
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>{{TITLE}}</title>
<style>
:root{color-scheme:dark;--bg:#0f1115;--panel:#171a21;--line:#2a2f3a;--fg:#e6e8ec;--dim:#9aa3b2;--ok:#4cc38a;--warn:#e5b454;--bad:#ef6b6b;--accent:#7aa2f7}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
nav{position:sticky;top:0;background:var(--panel);border-bottom:1px solid var(--line);padding:8px 16px;display:flex;gap:14px;flex-wrap:wrap}
nav a{color:var(--accent)} main{max-width:1200px;margin:0 auto;padding:16px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:12px} .pair img,.pair video{width:100%;height:auto}
@media (max-width:760px){.pair{grid-template-columns:1fr}}
figcaption,.dim{color:var(--dim);font-size:13px} .chip{border:1px solid var(--line);border-radius:999px;padding:1px 8px}
table{border-collapse:collapse;width:100%} td,th{border-bottom:1px solid var(--line);padding:4px 6px;text-align:left}
</style></head><body>
<nav><a href="#result">Result</a><!-- one link per scenario --><a href="#provenance">Provenance</a><a href="#verification">Verification</a><a href="#open">Open items</a></nav>
<main>
<section id="result"><h1>{{TITLE}}</h1><p>{{RESULT}}</p></section>
<section id="s01-wave-start"><h2>s01 · wave start <span class="chip">matched</span></h2>
  <div class="pair">
    <figure><img src="media/s01-wave-start/baseline-abc1234/moment-first-hit.png" alt="baseline abc1234, first-hit"><figcaption>BASELINE abc1234 · frame 40 · unedited capture · <a download href="media/s01-wave-start/baseline-abc1234/moment-first-hit.png">PNG</a></figcaption></figure>
    <figure><img src="media/s01-wave-start/candidate-def5678/moment-first-hit.png" alt="candidate def5678, first-hit"><figcaption>CANDIDATE def5678 · frame 40 · unedited capture · <a download href="media/s01-wave-start/candidate-def5678/moment-first-hit.png">PNG</a></figcaption></figure>
  </div>
</section>
<section id="open"><h2>Open items</h2><!-- physical devices · native fullscreen · accessibility · live integration --></section>
</main></body></html>
```

Write it, run the step 7 hash check again, then open it (`open` on macOS, `xdg-open` on Linux) unless `--no-open`. Print the absolute path either way.

### 10. Clean up, then report back

```bash
kill "$BASELINE_SERVER_PID" "$CANDIDATE_SERVER_PID" 2>/dev/null || true
git -C "$REPO" worktree remove --force "$RUN/baseline"
git -C "$REPO" worktree remove --force "$RUN/candidate"
```

Stop only the PIDs you recorded. Confirm each is gone, remove the temporary browser profiles, and drop the run directory once the media is copied out. `--force` deletes untracked files without asking, which is why nothing durable is written inside either worktree. Record in the report what was cleaned and anything that could not be, such as a port still bound, a worktree locked or a permission denied. Do not work around a permission prompt the owner declined. Record it as a blocker.

Report the absolute path of the report folder (it moves as a folder), the scenario chips, every gap and unavailable pair, and the open items. End the message, and the final message of any subagent this skill spawns, with the mechanical `**Status:**` block from the global `~/.claude/CLAUDE.md` ("End-of-message summary"), with four slots in order, `none` when empty and the 🔄 slot enumerated.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Stills differ in size between sides | the pixel ratio or viewport was set per side | one spec file; check the read-back values |
| Same frame index, different scene | the app reads a time source the clock does not cover | find it in source; fix the fixture or label the moments approximately matched |
| Digests differ at frame 0 | different seed, fixture or server state | compare the seeds; a gap if the baseline cannot take the seed |
| Placeholder art on one side | LFS pointers in a fresh worktree | `git lfs pull` in that worktree; hash the asset again |
| GIF panels drift apart | built from stills or from real-time video | build it from the two frame sequences |
| Labels cover the HUD | drawtext on the frame | pad a band outside the viewport, then draw |
| "Element visible" but not in the still | the claim came from a DOM query | look at the still; report the DOM line separately |

## Customization Points

- **Approved automation**: the browser automation package and version from the lockfile, and how to run it.
- **Build and serve**: the install, build and serve commands, the files the build writes, and any step to skip because it publishes.
- **Fixtures and clock**: the project's clock or deterministic-state fixture, the state digest hook, and the connection-only counters with their meaning in source.
- **Scenario source**: where agreed scenarios live, and the default viewport and pixel ratio.
- **Assets**: the served binary assets to hash, and whether the repo uses LFS.
- **Font**: a font file path for the GIF label band.
- **Output directory**: `--dir`, `$CLAUDE_BRIEF_DIR` or `~/.claude/briefs/`.
