# /look-approve

Get a visual deliverable **approved** — by showing it, not describing it. Runs the
real app from an isolated worktree of the approval target, captures **moving**
evidence (an animated GIF tour plus one still per feature under review), emits a
SHORT one-screen approval card as a self-contained HTML file, puts a single
approve / approve-with-notes / reject question to the owner, and records the
verdict on the tracking issue. The deliverable is a visual and a *"we gotta do
this"* — never six pages of prose. Reach for it when a UI/art/feel change is
sitting on `main` waiting for a human to say yes.

## What this is not

- **Not a code review** (`/agent-review`) — nothing here reads a diff.
- **Not a smoke test** (`/smoke-form`) — that hands a checklist to a human tester
  and collects pass/fail. This one *shows the owner the thing* and collects one
  verdict.
- **Not a status brief** (`/visual-brief`) — a brief informs; this asks. One
  screen, one ask. If you are writing a third paragraph, you are writing the
  wrong artifact.

## Arguments

- `$ARGUMENTS` — what is being approved, plus optional flags:
  - Free text = the review set (e.g. `epic #42`, `PRs #51-#58`,
    `the art pass on main`). If empty, infer from the session: what merged since
    the last approval that has a visible surface.
  - `--target REF` — git ref to capture from (default: `origin/main`; the thing
    being approved is what is *on the branch*, not what is in your worktree).
  - `--dir PATH` — output directory (overrides the default below).
  - `--no-open` — write the card but don't launch the browser.

## Output location (resolution order)

1. `--dir PATH` if given.
2. `$CLAUDE_BRIEF_DIR` if set — point it at an Obsidian vault subfolder so the
   approved-state record is durable and linkable.
3. Default: `~/.claude/briefs/` (created if missing).

```
<dir>/look-approve-<slug>-<YYYY-MM-DD>.html   ← the card
<dir>/assets/<slug>/tour.gif                  ← hero
<dir>/assets/<slug>/still-<nn>-<label>.png    ← one per feature/PR
```

Never overwrite — append `-2`, `-3` on collision. The card references its assets
by relative path, so **the HTML and its `assets/<slug>/` folder move together**;
say so when you report the path.

## Instructions

### 1. Establish the review set — what is actually being approved

Pull it, don't guess:

```bash
gh issue view <epic> --json number,title,body,state
gh pr list --state merged --search "<epic-or-milestone>" --json number,title,mergedAt
```

Write one line per item: **number · title · what it should LOOK like on screen.**
That third column is the filter:

- If you cannot name a visible outcome for an item, it does not belong on the
  card. List it separately as **"not visually verifiable — covered by tests/CI"**
  and move on. A card padded with invisible work teaches the owner to skim.
- 3–8 items is the target. More than that and the thumbnail grid stops being
  scannable — split into two approval passes by surface.
- Each surviving item earns **exactly one still**. That 1:1 mapping is the
  contract: still ↔ feature/PR, no orphans in either direction. An item you
  cannot capture a still for is an item you cannot claim was verified.

{{CUSTOMIZE: where the review set comes from in this repo — the epic/tracking issue convention, the label or milestone that groups a wave, and how PRs reference it}}

### 2. Isolated worktree — always, no exception

```bash
REPO={{CUSTOMIZE: absolute path to this repo's working copy}}
WT="$(mktemp -d)/lookapprove-$(date +%s)"
git -C "$REPO" fetch origin
git -C "$REPO" worktree add --detach "$WT" "${TARGET_REF:-origin/main}"
```

- **Never capture from the shared checkout.** Running the app writes into the
  project (import caches, generated artifacts, editor state) and other sessions
  share that tree's `git` HEAD. `--detach` because you are photographing a ref,
  not developing on it.
- **Capture-only.** No commits, no pushes, no branch creation in the target repo.
  Nothing the capture produces is committed there — the card and its assets live
  in the brief directory, outside the repo.
- **Verify binary assets materialised** before you trust a single frame. In a
  fresh worktree of an LFS repo, art can arrive as pointer text and the app will
  render placeholders you would then present as the deliverable:
  ```bash
  file "$WT/{{CUSTOMIZE: path to a representative binary asset, e.g. a texture}}"
  # want: "PNG image data …"   NOT: "ASCII text"  → then: git -C "$WT" lfs pull
  ```
- Remove it when the pass is done: `git -C "$REPO" worktree remove --force "$WT"`. `--force`
  deletes every untracked file in `$WT` without prompting, which is fine for frames and fatal
  for anything durable — if a session handoff seed (`docs/handoffs/`) or any other keeper was
  written here, commit and push it **first**, and confirm with
  `git -C "$REPO" cat-file -e <branch>:<path>`.

### 3. Protect the owner's real data — before anything launches

The capture runs the **real application**, which reads and writes the **real**
user-data location — the worktree isolates the code, not the app's data
directory. Back it up and restore it, every run:

```bash
SAVE_DIR="{{CUSTOMIZE: the app's real user-data path, e.g. ~/Library/Application Support/<Company>/<Product>}}"
BACKUP="$(mktemp -d)/save-backup"
if [ -e "$SAVE_DIR" ]; then
  mkdir -p "$BACKUP" && cp -R "$SAVE_DIR" "$BACKUP/" || exit 1
  # Restore on ANY exit — success, failure, or Ctrl-C. A capture that dies
  # mid-tour is exactly when the save is left in the state the tour put it in.
  trap 'rm -rf "$SAVE_DIR" && cp -R "$BACKUP/$(basename "$SAVE_DIR")" "$SAVE_DIR"' EXIT INT TERM
fi
```

This is not defensive boilerplate: the prototype this skill was distilled from
**overwrote a live save** on its first run. Also consider local databases,
credential stores, and any cloud-sync session the app signs into. If the project
genuinely persists nothing, say so out loud in your report rather than skipping
the step silently.

### 4. Capture — the adapter contract

Every engine adapter, whatever it drives, produces the same five things into one
frames directory. The rest of this skill only knows about these:

| Artifact | Meaning |
|---|---|
| `frame_NNNN.png` | ordered capture frames at a fixed fps |
| `_STILLS.json` | `{"<label>": <frame index>}` — one entry per feature/PR |
| `_STAGED.txt` | one line per action the tour staged (the honesty record) |
| `_RUN.json` | resolution, fps, frame count, engine/app version |
| `_DONE.txt` | completion sentinel, written on success **and** on abort |

**Wait on the sentinel, never on CPU or log activity.** A cold cache compiles
shaders or bundles for a minute or more at the first frame and is indistinguishable
from a hang:

```bash
for _ in $(seq 1 240); do [ -f "$FRAMES/_DONE.txt" ] && break; sleep 5; done
[ -f "$FRAMES/_DONE.txt" ] || { echo "capture never completed — see $LOG" >&2; exit 1; }
```

#### 4a. Unity adapter (proven)

The reference implementation ships in the registry at
`assets/LookApproveCapture.cs`. **It is not installed with this skill** —
`skill add` writes only `.claude/commands/<name>.md`, so fetch it the way
`/skill` fetches its own compiler:

```bash
# local registry clone (preferred; $REG is the resolved registry path)
cp "$REG/assets/LookApproveCapture.cs" "$WT/{{CUSTOMIZE: path to an Editor/ folder in this project}}/"

# no clone on disk — fetch it, and fail loudly rather than half-fetching
set -o pipefail
gh api repos/blamechris/skill-templates/contents/assets/LookApproveCapture.cs \
  --jq '.content' | base64 -d > "$WT/<Editor>/LookApproveCapture.cs" || exit 1
[ -s "$WT/<Editor>/LookApproveCapture.cs" ] || { echo "adapter fetch failed" >&2; exit 1; }
```

It goes into the **worktree**, never the shared checkout, and is never committed.
Unity generates the `.meta` itself.

**Pick the editor that matches the project**, or the run burns minutes on an
upgrade prompt:

```bash
UV=$(sed -n 's/^m_EditorVersion: //p' "$WT/ProjectSettings/ProjectVersion.txt")
UNITY="/Applications/Unity/Hub/Editor/$UV/Unity.app/Contents/MacOS/Unity"
[ -x "$UNITY" ] || { echo "editor $UV not installed" >&2; ls /Applications/Unity/Hub/Editor/; exit 1; }
```

**Invoke it headed:**

```bash
LOOKAPPROVE_OUT="$FRAMES" \
LOOKAPPROVE_TOUR="$TOUR_JSON" \
LOOKAPPROVE_SAVES=backed-up \
"$UNITY" -projectPath "$WT" \
         -executeMethod LookApprove.EditorTools.LookApproveCapture.Run \
         -logFile "$LOG" &
```

Everything below was learned the hard way; none of it is optional:

- **`-batchmode -nographics` cannot render.** There is no frame to capture without
  a graphics device. Launch headed. The editor window does **not** need focus and
  you can keep working in other apps while it runs.
- **Entering play mode reloads the domain**, wiping every static field. Carry run
  state in `SessionState`, re-attach with `[InitializeOnLoadMethod]`, and drive
  from `EditorApplication.update` gated on `Time.frameCount` changing — editor
  ticks are not game frames, and stepping the tour per editor tick produces a
  stutter that reads as a rendering bug.
- **`Time.captureFramerate`** for a deterministic, drop-free cadence: the engine
  advances by exactly 1/fps regardless of real-time render speed.
- **Enter play mode only when the editor is idle** (`!isCompiling && !isUpdating`);
  the request is silently dropped otherwise.
- **Hide editor-only debug overlays** (the `UNITY_EDITOR`-compiled `OnGUI` kind)
  before the first frame — they are not part of what is being approved and they
  sit in *every* frame.
- **Dismiss boot-time modals** (offline-progress screens, tutorials) that would
  cover the establishing shot. If a modal is itself under review, script it as a
  deliberate late beat instead.
- **Fixed Game View size uses internal API** (`UnityEditor.GameView`,
  `UnityEditor.GameViewSizes`). Keep the `try`/`catch` fallback to a plain window
  resize — this API is unsupported and moves between versions; losing a whole
  capture over framing is a bad trade.
- **Benign log noise — do not chase it:** the `Licensing::Module` handshake
  failure and a QuickSearch `ArgumentOutOfRangeException` at startup both appear
  on healthy runs.
- **Budget ~4 minutes** end-to-end per run on a warm `Library/`; the first run
  after a fresh worktree is much longer (shader/asset import).

The tour itself is data — a JSON spec of beats (`hold`, `walk`, `cue`), read from
`LOOKAPPROVE_TOUR`. `still` on a beat names the feature that beat proves, and the
label lands in `_STILLS.json`. **A `cue` without a `declare` string aborts the
run** — see step 7.

{{CUSTOMIZE: this project's tour spec — scene path, capture resolution/fps, the named waypoints the tour walks between, overlays to hide, modals to dismiss}}

#### 4b. Web adapter (extension point)

Serve the built app from the worktree, drive it with a headless-capable browser
(Playwright/Puppeteer), and screenshot on a fixed interval into the same
`frame_NNNN.png` sequence — the frames dir, the four manifests and the sentinel
are unchanged. Freeze animations to a deterministic clock rather than sleeping.

#### 4c. Native / mobile adapter (extension point)

Build for a simulator/emulator, drive the UI with the platform's automation
(XCUITest, `xcrun simctl`, `adb`/UIAutomator), and capture either frame-by-frame
screenshots or a screen recording you then decompose into the same sequence.
Reset the simulator's app container instead of trusting step 3's backup.

#### 4d. CLI / TUI adapter (extension point)

Record the terminal (`asciinema`, or a PTY driver) while a scripted session runs
against the worktree build, then render to frames. The "stills" are moments in the
session; the same 1:1 still ↔ feature contract applies.

### 5. Assemble the GIF and the stills

```bash
# Long edge ≈800px — read the ACTUAL frame size; a portrait app is 450x800,
# not 800 wide, and guessing landscape squashes the whole tour.
SIZE=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
       -of csv=p=0:s=x "$FRAMES/frame_0000.png")
W=${SIZE%x*}; H=${SIZE#*x}
if [ "$W" -ge "$H" ]; then SCALE="800:-1"; else SCALE="-1:800"; fi

# Two-pass palette. `dither=none` — flat/low-poly art dithers into visible noise
# that reads as a rendering artifact and derails the approval into a bug report.
FILT="fps=12,scale=$SCALE:flags=lanczos"
ffmpeg -y -framerate "$FPS" -i "$FRAMES/frame_%04d.png" \
  -vf "$FILT,palettegen=stats_mode=diff" "$TMPD/palette.png"
ffmpeg -y -framerate "$FPS" -i "$FRAMES/frame_%04d.png" -i "$TMPD/palette.png" \
  -lavfi "$FILT[x];[x][1:v]paletteuse=dither=none" "$ASSETS/tour.gif"
```

- **≤15 seconds, ~12fps.** Past that the owner scrubs instead of watching, and the
  file gets too heavy to open from a vault on a phone. If the tour is longer, it
  is two approval passes.
- Keep `tour.gif` under ~4 MB. Over budget → drop fps or trim beats, never
  upscale-then-compress.
- **Stills come from the manifest, not from your memory of the run:**
  ```bash
  python3 - "$FRAMES/_STILLS.json" "$FRAMES" "$ASSETS" <<'PY'
  import json, shutil, sys, re
  manifest, frames, out = sys.argv[1:4]
  for i, (label, idx) in enumerate(json.load(open(manifest)).items(), 1):
      slug = re.sub(r'[^a-z0-9]+', '-', label.lower()).strip('-')
      shutil.copy(f"{frames}/frame_{idx:04d}.png", f"{out}/still-{i:02d}-{slug}.png")
      print(f"still-{i:02d}-{slug}.png  <- frame {idx}  ({label})")
  PY
  ```
- **Reconcile before you build the card:** every review-set item has a still and
  every still has an item. A mismatch is a finding, not a rounding error — either
  capture the missing beat or move the item to the honesty callout as *not
  exercised*.

### 6. The card — ONE screen

Self-contained HTML (inline `<style>`, no CDN, no framework) referencing
`assets/<slug>/`. Top to bottom, and that is the whole document:

1. **Title line** — what is being approved + the ref and short SHA it was captured
   from. One line.
2. **Hero GIF** — full width, `loop`, nothing over it.
3. **Thumbnail grid** — one still per item, each captioned with its number and a
   ≤6-word claim ("#47 — customers now differ by colour"). The caption is the
   claim the owner is being asked to accept.
4. **Honesty callout** — exactly one block, always present (step 7).
5. **Verdict ask** — the three options, verbatim, so the owner knows what the
   question in chat will be. The card does not collect the answer.

Hard limits: **no prose section**, no per-PR narrative, no metrics table, no
"next steps". Everything the owner needs to decide fits above the fold on a
laptop. If something genuinely cannot be shown in a still, it goes in the honesty
callout in one clause — not a paragraph.

Reuse the house palette and chrome from `/visual-brief`'s skeleton (CSS variables
for **both** `:root` dark and the `prefers-color-scheme: light` block — a
hardcoded hex renders correct for you and broken for the reader). Only the layout
differs:

```html
<div class="wrap">
  <header><div class="eyebrow">APPROVAL</div><h1>{{TITLE}}</h1>
    <p class="sub">captured from {{REF}} @ {{SHA}} · {{DATE}}</p></header>
  <img class="hero" src="assets/{{SLUG}}/tour.gif" alt="{{TITLE}} tour">
  <div class="grid">
    <figure><img src="assets/{{SLUG}}/still-01-….png"><figcaption>#47 — …</figcaption></figure>
    <!-- one per review-set item -->
  </div>
  <div class="callout"><b>Staged for the camera:</b> {{HONESTY}}</div>
  <section class="ask"><h2>Verdict</h2>
    <ol><li><b>Approve</b> — ship it</li>
        <li><b>Approve with notes</b> — ship it, file the notes as follow-ups</li>
        <li><b>Reject</b> — name what's wrong, it goes back</li></ol></section>
</div>
```

Style notes: `.hero{width:100%;border-radius:14px}`,
`.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}`,
`figure{margin:0}`, `figcaption{font-size:12.5px;color:var(--dim);margin-top:6px}`.
Never put loose text directly inside a `display:flex` parent — each run becomes
its own flex item and collapses to one word per column.

Write it, then open it (`open` on macOS / `xdg-open` on Linux) unless `--no-open`.
Opening is a convenience, never a gate — print the absolute path regardless.

### 7. Honesty callouts are mandatory

**Anything staged, forced, or not actually exercised during the capture is
declared on the card.** Not in your chat message, not in a log — on the card the
owner looks at while deciding. This is what makes the approval mean anything.

Declare, in one clause each:

- **Staged actions** — every cue the tour fired to make something happen inside
  its 15 seconds (spawns forced, currency granted, timers advanced, a modal
  presented directly). The Unity adapter enforces this mechanically: a cue
  without a `declare` string aborts the run before play mode, and the
  declarations land in `_STAGED.txt` verbatim. Copy them; don't paraphrase them
  into vagueness.
- **Not exercised** — any review-set item whose still shows the *surface* but
  whose behaviour the tour never triggered.
- **Environment deltas** — debug overlays hidden, boot modals dismissed,
  simulated hardware, a fixed viewport that differs from the shipping one.
- **Failed cues** — a cue that threw is a beat that did not happen. Say the beat
  is missing rather than letting the frame speak for something it does not show.

If **nothing** was staged, say that explicitly: *"Nothing staged — the tour ran on
the game's own behaviour."* An empty callout block is indistinguishable from a
forgotten one, so the block is always there.

The card's claim is *"this is what it looks like"*. The moment it implies *"and
this all happened on its own"* when it did not, the next approval is worthless
too.

### 8. Ask for the verdict — one `AskUserQuestion`, three options

One call, immediately after the card opens. Never a paragraph ending in a
question mark, never a drip-feed of one question per item:

- **Approve** — ship it. The epic closes.
- **Approve with notes** — ship it; the notes become follow-up issues (per the
  follow-on protocol: in-scope and ≤15 min folds into the current work, anything
  else is a scoped issue).
- **Reject** — name what is wrong; the epic stays open and the named items go
  back with the reason attached.

Lead with your recommendation and say what it costs. State the default if they
don't answer: **nothing ships** — a visual approval with no answer is not an
approval, and silence is never consent for an outward-facing change.

{{CUSTOMIZE: fallback channel if `AskUserQuestion` is unavailable in the target agent — the shape (three labelled options, recommendation first, explicit no-answer default) is the requirement; the tool is the default carrier}}

### 9. Record the verdict durably

A verdict that lives only in a chat transcript did not happen. Write it back,
referencing the epic and every item number:

```bash
gh issue comment <epic> --body "$(cat <<'EOF'
## Visual approval — <date>

**Verdict:** <approved | approved with notes | rejected>
**Captured from:** <ref> @ <sha> · <N> frames @ <fps>fps
**Card:** <absolute path to the .html>

| Item | Still | Outcome |
|---|---|---|
| #47 | still-01-… | approved |

**Staged for the capture:** <the honesty callout, verbatim>
**Notes:** <the owner's words, verbatim — not your summary of them>
EOF
)"
```

Then advance the tracker per the answer:

- **Approve** → close the epic (`gh issue close <epic> --reason completed`) and
  any per-item issues the verdict settles.
- **Approve with notes** → close the epic, file each note as its own scoped issue
  (`/create-issue`), and link them from the comment.
- **Reject** → leave the epic open, re-open or label the failing items, and put
  the owner's reason in each one so the next agent doesn't re-litigate it.

{{CUSTOMIZE: this repo's tracker conventions — labels for approved/rejected visual passes, whether epics close on approval or move to a project column, and which issue the record comment belongs on}}

### 10. Clean up, then report

```bash
git -C "$REPO" worktree remove --force "$WT"
```

Frames are large and disposable — keep the GIF and the stills, drop the frames
dir (or keep it only when the verdict was *reject*, so the next pass can diff).
The save-data restore from step 3 has already fired via its `trap`; confirm the
real save is back before you say you are done.

Report: the card's absolute path, the verdict, the issue you recorded it on, and
anything in the honesty callout. End the message with the mechanical `**Status:**`
line — the four fixed slots defined in the global `~/.claude/CLAUDE.md`
("End-of-message summary"); follow it from there rather than restating it.

## Failure modes, and what they actually mean

| Symptom | Cause | Fix |
|---|---|---|
| Zero frames, no error | headless launch | drop `-batchmode -nographics`; render needs a display |
| "Hung" for ~90s at first frame | shader/asset compilation | wait on `_DONE.txt`, not on CPU or log tail |
| Tour steps in bursts | driver ticking per editor update | gate on the game frame counter changing |
| Placeholder/pink art | LFS pointers in the fresh worktree | `git lfs pull` in the worktree; `file` the asset to confirm |
| Frames stall mid-tour | play mode exited early | the driver must detect it and finish honestly, not hang |
| Wrong aspect / squashed GIF | assumed landscape | read the frame size and scale the long edge |
| Speckled flat colour | GIF dithering | `paletteuse=dither=none` |
| Modal covers everything | boot-time popup | dismiss it in the adapter, or script it as a late beat |
| A real save was clobbered | step 3 skipped | backup + `trap`-restore is mandatory, every run |

## Notes

- **The capture is evidence, not decoration.** If the tour did not actually
  exercise a feature, the card says so — a beautiful GIF that overstates the
  build costs more trust than it buys.
- **One pass, one ask.** If the review set won't fit on one screen, run two
  passes rather than growing the card.
- **Re-run on reject.** A rejected pass ends with a new capture, not with a
  paragraph explaining why the first one was fine.
- Everything the capture writes is disposable and lives outside the target repo.
  `/look-approve` never commits to the repo it photographs.

## Customization Points

- **Engine adapter** — which of §4a–4d this repo uses, and its concrete
  invocation. Unity is documented end-to-end; the others are shapes to fill in.
- **Tour spec** — scene/route, capture resolution and fps, waypoints, overlays to
  hide, modals to dismiss.
- **User-data path** — what step 3 backs up and restores (`none` is a valid
  answer, but state it).
- **Review-set source** — the epic/tracking-issue convention and the label or
  milestone that groups a wave.
- **Tracker conventions** — labels and state transitions for approve /
  approve-with-notes / reject.
- **Output directory** — `$CLAUDE_BRIEF_DIR` or `~/.claude/briefs/`; point it at
  an Obsidian vault subfolder for a durable approval record.
