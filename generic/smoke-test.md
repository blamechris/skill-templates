# /smoke-test

Run an automated visual smoke test of the application using Playwright. Launches a headless browser, navigates through key UI flows, takes screenshots, and reports pass/fail results.

## Arguments

- `$ARGUMENTS` - Optional flags:
  - `--headed` — Show the browser window (useful for debugging)
  - `--keep-screenshots` — Don't clean up screenshots after the run
  - If empty, runs headless and cleans up screenshots

## Instructions

### 0. Prerequisites

Verify Playwright is installed and the test script exists:

```bash
# Check Playwright is available
node -e "require('playwright')" 2>/dev/null || {
  echo "Installing Playwright..."
  npm install --save-dev playwright
  npx playwright install chromium
}

# Check smoke test script exists
{{CUSTOMIZE: Path to smoke test script}}
```

### 1. Ensure Application is Running

The smoke test connects to a running application instance. Check if one is already running, or start one:

```bash
{{CUSTOMIZE: How to detect and start the application}}
```

### 2. Run the Smoke Test

**Do NOT forward `$ARGUMENTS` verbatim to `playwright test`.** Only `--headed` is a real
Playwright flag; `--keep-screenshots` is a skill-level flag handled by this skill's
cleanup step (5), not Playwright. Parse the two out separately:

```bash
PW_FLAGS=""
KEEP_SCREENSHOTS=false
for arg in $ARGUMENTS; do
  case "$arg" in
    --headed) PW_FLAGS="$PW_FLAGS --headed" ;;
    --keep-screenshots) KEEP_SCREENSHOTS=true ;;  # skill-level, NOT passed to Playwright
    *) ;;  # ignore unknown flags rather than forwarding them
  esac
done

# {{CUSTOMIZE: Command to run the smoke test script — append only $PW_FLAGS, e.g.
#   npx playwright test smoke.spec.ts $PW_FLAGS
# Never append $ARGUMENTS or $KEEP_SCREENSHOTS here.}}
```

The test script should:
- Connect to the running application
- Navigate through key UI flows
- Take screenshots at each step (saved to a gitignored directory)
- Output PASS/FAIL for each check
- Exit 0 (all pass) or 1 (failures)

### 3. Read Screenshots

After the test runs, read each screenshot to visually verify the UI:

```bash
# Screenshots are saved to a temporary directory
{{CUSTOMIZE: Screenshot directory path}}
```

Use the Read tool to view each screenshot image. For each screenshot:
- Verify the UI looks correct (layout, colors, text, element positions)
- Check for visual regressions (missing elements, broken layouts, overlapping content)
- Note any issues that the automated checks might have missed

### 4. Report Results

Output a summary table:

```markdown
## Smoke Test Results

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1 | App loads | PASS | HTTP 200, no console errors |
| 2 | Feature X visible | PASS | — |
| 3 | Feature Y works | FAIL | Element not found |

**Screenshots reviewed:** N
**Visual issues found:** M (describe any issues)

{{CUSTOMIZE: Any repo-specific follow-up actions}}
```

### 5. Cleanup

```bash
# Remove screenshots unless --keep-screenshots was passed (parsed in step 2, NOT
# forwarded to Playwright). $KEEP_SCREENSHOTS is the skill's own flag.
if [ "$KEEP_SCREENSHOTS" != "true" ]; then
  {{CUSTOMIZE: Cleanup command — e.g., rm -rf "$SCREENSHOT_DIR"}}
fi
```

If the application was started by this skill (not already running), stop it.

## Writing the Smoke Test Script

If the test script doesn't exist yet, create it following these patterns:

### Script Structure

```javascript
/**
 * Smoke Test — Playwright-based visual verification
 *
 * Prerequisites: application must be running.
 * Screenshots saved to {{CUSTOMIZE: screenshot dir}} (gitignored).
 */

import { chromium } from 'playwright'
// ... setup

async function run() {
  // 1. Find running application
  // 2. Launch browser
  // 3. Navigate to app URL (with auth if needed)
  // 4. Wait for app to be ready (WebSocket, data loading, etc.)
  // 5. Run checks — each one:
  //    a. Interact with UI (click, type, navigate)
  //    b. Take screenshot
  //    c. Assert element exists / is visible / has correct content
  //    d. Log PASS or FAIL
  // 6. Output summary
  // 7. Exit with appropriate code
}
```

### Check Patterns

Each check should:
1. **Act** — Navigate, click, type
2. **Screenshot** — Capture current state
3. **Assert** — Verify expected elements/content
4. **Report** — Log PASS/FAIL with details

```javascript
// Example: Check a modal opens
await page.keyboard.press('Control+n')
await page.waitForTimeout(500)
await screenshot(page, '02-modal-open')

const modal = await page.$('.modal-overlay')
if (modal && await modal.isVisible()) {
  pass('Modal opens')
} else {
  fail('Modal opens', 'Not visible after Ctrl+N')
}
```

### Selector Strategy

Prefer stable selectors in this order:
1. `aria-label`, `role`, `data-testid` attributes
2. Class names matching component names
3. Semantic HTML elements (`header`, `main`, `nav`)
4. Text content (last resort — fragile)

### Connection Handling

Many apps need a backend connection before the full UI renders. Always wait for the "ready" state:

```javascript
// Wait for app to be fully loaded and connected
await page.waitForFunction(() => {
  // App-specific readiness check
  {{CUSTOMIZE: readiness check}}
}, { timeout: 10000 })
```

## Test Categories

Organize checks into logical groups:

{{CUSTOMIZE: Test categories and what they verify}}

## Critical Rules

1. **Never send real messages** — Smoke tests verify UI, not backend processing. Don't submit forms that trigger expensive operations.
2. **Screenshots are temporary** — Always clean up unless `--keep-screenshots`. Add the directory to `.gitignore`.
3. **Fail fast on no connection** — If the app isn't running or can't connect, report immediately instead of running checks that will all fail.
4. **Stable selectors** — Use aria labels and roles, not brittle CSS class names that change with refactors.
5. **Visual verification is the point** — The automated checks catch DOM presence. Reading screenshots catches visual regressions (z-index, color, spacing).
6. **Idempotent** — Safe to run repeatedly. Don't create persistent state (sessions, data, etc.) that would affect the next run.

## Customization Notes

{{CUSTOMIZE: Describe repo-specific context for deploy.sh}}

Lines marked with `{{CUSTOMIZE}}` need repo-specific adaptation:
- Application start/detect commands
- Smoke test script path and command
- Screenshot directory
- Auth handling (tokens, cookies, etc.)
- Readiness check (WebSocket, API, static page)
- Test categories matching the app's feature set
- Cleanup and follow-up actions
