#!/usr/bin/env node
// Unit tests for deriveDescription (assets/compile-skill-targets.mjs).
// Run: node assets/compile-skill-targets.test.mjs
// Focus: twitch-status-updater#737 — the sentence split must not cut at the
// period inside common abbreviations ("e.g.", "i.e.", …) or inside a still-open
// "(…" parenthetical.
import { strict as assert } from 'node:assert'
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  deriveDescription,
  detectUncompiledAgents,
  emitPi,
  ALL_TARGETS,
} from './compile-skill-targets.mjs'

// A lone surrogate = a half-cut astral character. Emitting one into a YAML/TOML
// `description:` is the bug the grapheme cap exists to prevent.
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/

let n = 0
function t(label, fn) {
  n++
  try {
    fn()
    console.log(`  ok ${n} - ${label}`)
  } catch (err) {
    console.error(`  FAIL ${n} - ${label}`)
    console.error(err.message)
    process.exit(1)
  }
}

t('plain first sentence still cuts at the first period', () => {
  assert.equal(
    deriveDescription('First sentence here. Second sentence must be dropped.\n', 'x'),
    'First sentence here.'
  )
})

t('does not cut at "e.g." inside a parenthetical (#737 regression)', () => {
  const body = 'Defines when a session (e.g. `/a`, `/b`) may merge its own PR. More prose follows.\n'
  assert.equal(deriveDescription(body, 'x'), 'Defines when a session (e.g. `/a`, `/b`) may merge its own PR.')
})

t('does not cut at "i.e.", "etc.", "vs.", or "cf." mid-sentence', () => {
  for (const abbr of ['i.e.', 'etc.', 'vs.', 'cf.']) {
    const body = `Compares apples ${abbr} oranges in detail. Trailing sentence.\n`
    assert.equal(deriveDescription(body, 'x'), `Compares apples ${abbr} oranges in detail.`, abbr)
  }
})

t('does not cut at a period inside an unclosed parenthetical', () => {
  const body = 'Runs the gate (see notes. incl. caveats) then reports the verdict. Extra sentence.\n'
  assert.equal(deriveDescription(body, 'x'), 'Runs the gate (see notes. incl. caveats) then reports the verdict.')
})

t('accumulates a first sentence that wraps across physical lines', () => {
  const body = '# Title\n\nDefines the gate (e.g.\n`/flow`) for merges.\nSecond sentence dropped.\n'
  assert.equal(deriveDescription(body, 'x'), 'Defines the gate (e.g. `/flow`) for merges.')
})

t('caps an over-long first sentence with an ellipsis', () => {
  const body = 'A'.repeat(200) + '. Next.\n'
  const desc = deriveDescription(body, 'x')
  assert.equal(desc.length, 160)
  assert.ok(desc.endsWith('...'))
})

t('ellipsis cap trims to the last word boundary — no mid-word stump (#748)', () => {
  // 40x "word " = a 199-char single "sentence" (no period before the cap).
  // slice(0,157) ends mid-word ("…word wo"); the boundary trim must drop the
  // " wo" stump, leaving 31 whole words + "...".
  const body = 'word '.repeat(40) + '\n'
  const desc = deriveDescription(body, 'x')
  assert.equal(desc, 'word '.repeat(30) + 'word...')
  assert.ok(desc.length <= 160)
})

t('capped description never ends in a partial word (property check)', () => {
  const words = 'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu'
  const body = `${words} ${words}\n`
  const desc = deriveDescription(body, 'x')
  assert.ok(desc.length <= 160)
  assert.ok(desc.endsWith('...'))
  assert.ok(/\S\.\.\.$/.test(desc), 'no whitespace before the ellipsis')
  const kept = desc.slice(0, -3)
  const orig = `${words} ${words}`
  assert.ok(orig.startsWith(kept), 'kept text is a prefix of the source')
  assert.equal(orig[kept.length], ' ', 'cut lands exactly on a word boundary')
})

t('a single unbroken token longer than the cap keeps the hard cut (no boundary to back up to)', () => {
  const body = 'B'.repeat(300) + '\n'
  const desc = deriveDescription(body, 'x')
  assert.equal(desc.length, 160)
  assert.equal(desc, 'B'.repeat(157) + '...')
})

t('a cut that already lands on a space keeps the whole word (#760 review)', () => {
  // "a " x100 -> a 199-char paragraph whose char 157 is a SPACE, so slice(0,157)
  // already ends on a complete word. Backing up unconditionally would throw away
  // that good word; the boundary trim must fire only on a mid-word cut.
  const body = 'a '.repeat(100) + '\n'
  const desc = deriveDescription(body, 'x')
  assert.equal(desc.length, 160, 'no word dropped: the full 157-char cut is kept')
  assert.equal(desc, 'a '.repeat(78) + 'a...')
})

t('a description shorter than the cap is returned unchanged (no ellipsis)', () => {
  const body = 'Short prose with no terminal period\n'
  assert.equal(deriveDescription(body, 'x'), 'Short prose with no terminal period')
})

t('a description exactly at the 160 cap is not truncated', () => {
  const body = 'c'.repeat(160) + '\n'
  const desc = deriveDescription(body, 'x')
  assert.equal(desc.length, 160)
  assert.equal(desc, 'c'.repeat(160))
  assert.ok(!desc.endsWith('...'))
})

t('falls back to the project-skill stub for a body with no prose', () => {
  assert.equal(deriveDescription('# Only a heading\n', 'my-skill'), 'Project skill: /my-skill')
})

t('a paragraph ending in a bare abbreviation returns whole paragraph (no dangling cut)', () => {
  assert.equal(deriveDescription('Handles common cases e.g.\n', 'x'), 'Handles common cases e.g.')
})

// --- grapheme-safe cap -----------------------------------------------------
// The UTF-16 cap these replace broke at emoji offset 156 (plain) and 147/150/153/156
// (ZWJ family cluster). Sweeping every offset, rather than asserting the four known
// ones, keeps the test honest if the cap constant ever moves.

t('never emits a lone surrogate — plain emoji at any offset around the cut', () => {
  const broken = []
  for (let k = 140; k <= 170; k++) {
    const desc = deriveDescription('x'.repeat(k) + '😀' + 'y'.repeat(80) + '\n', 'x')
    if (LONE_SURROGATE.test(desc)) broken.push(k)
  }
  assert.deepEqual(broken, [], `split an astral pair at emoji offset(s): ${broken.join(',')}`)
})

t('never emits a lone surrogate — ZWJ family cluster at any offset around the cut', () => {
  const broken = []
  for (let k = 140; k <= 170; k++) {
    const desc = deriveDescription('x'.repeat(k) + '👨‍👩‍👧‍👦' + 'y'.repeat(80) + '\n', 'x')
    if (LONE_SURROGATE.test(desc)) broken.push(k)
  }
  assert.deepEqual(broken, [], `split an astral pair at cluster offset(s): ${broken.join(',')}`)
})

t('the cap is a grapheme budget, not a UTF-16 one', () => {
  // 80 family clusters = 80 graphemes but 880 UTF-16 units. A UTF-16 cap would
  // truncate this to ~14 visible characters; a grapheme cap leaves it untouched.
  const body = '👨‍👩‍👧‍👦'.repeat(80) + '\n'
  const desc = deriveDescription(body, 'x')
  assert.ok(!desc.endsWith('...'), 'must not truncate 80 visible clusters')
  assert.equal(desc, '👨‍👩‍👧‍👦'.repeat(80))
})

t('abbreviation handling survives the grapheme rewrite (both fixes coexist)', () => {
  // The compiler this was merged with used a bare `search(/\.(\s|$)/)` and cut here
  // at "Runs e.g." — the grapheme cap must not have cost us sentenceEnd().
  assert.equal(
    deriveDescription('Runs e.g. the linter. Then it reports findings.\n', 'x'),
    'Runs e.g. the linter.'
  )
  assert.equal(
    deriveDescription('Fix the cap (see e.g. #137. still open) then ship. Next.\n', 'x'),
    'Fix the cap (see e.g. #137. still open) then ship.'
  )
})

// --- pi target -------------------------------------------------------------

t('pi is a known target', () => {
  assert.ok(ALL_TARGETS.includes('pi'))
  assert.deepEqual(ALL_TARGETS, ['claude', 'gemini', 'codex', 'pi'])
})

t('emitPi writes user-global SKILL.md with quoted name and description', () => {
  const out = emitPi('my-skill', 'Body prose here.\n', 'A description.')
  assert.ok(out.path.endsWith('/.pi/agent/skills/my-skill/SKILL.md'), out.path)
  assert.ok(out.content.startsWith('---\nname: "my-skill"\ndescription: "A description."\n---\n'))
  assert.ok(out.content.endsWith('Body prose here.\n'))
  assert.equal(out.warn, null)
})

t('emitPi quotes a name containing a YAML-significant char', () => {
  // Frontmatter must stay parseable even though the name is separately warned about.
  const out = emitPi('weird:name', 'Body.\n', 'D.')
  assert.ok(out.content.includes('name: "weird:name"'))
  assert.match(out.warn, /not Pi-valid/)
})

t('emitPi warns on inline arg tokens but ignores them inside fenced code', () => {
  assert.match(emitPi('a', 'Pass $ARGUMENTS through.\n', 'D.').warn, /NOT substituted/)
  assert.match(emitPi('a', 'See $1 below.\n', 'D.').warn, /NOT substituted/)
  assert.equal(emitPi('a', 'Run it:\n\n```sh\necho $1 $ARGUMENTS\n```\n', 'D.').warn, null)
})

// --- detectUncompiledAgents ------------------------------------------------

function withHome(dirs, fn) {
  const home = mkdtempSync(join(tmpdir(), 'skill-home-'))
  try {
    for (const d of dirs) mkdirSync(join(home, d), { recursive: true })
    fn(home)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}

t('flags an installed-but-unselected pi (~/.pi present)', () => {
  withHome(['.pi'], (home) => {
    assert.deepEqual(detectUncompiledAgents(['claude', 'gemini'], home), ['pi'])
  })
})

t('does not flag pi when it IS a selected target', () => {
  withHome(['.pi'], (home) => {
    assert.deepEqual(detectUncompiledAgents(['claude', 'pi'], home), [])
  })
})

t('never flags codex — it is repo-tracked here, so ~/.codex proves nothing', () => {
  // The upstream compiler DID flag codex, because there it emitted to
  // ~/.codex/prompts/. This registry emits .codex/skills/ into the repo (#111), so a
  // codex home dir carries no information about compile coverage — same as gemini.
  withHome(['.codex', '.gemini'], (home) => {
    assert.deepEqual(detectUncompiledAgents(['claude'], home), [])
  })
})

t('returns nothing when no agent home dirs exist', () => {
  withHome([], (home) => {
    assert.deepEqual(detectUncompiledAgents(['claude'], home), [])
  })
})

console.log(`\ncompile-skill-targets.test: ALL PASS (${n} tests)`)
