#!/usr/bin/env node
// Unit tests for deriveDescription (assets/compile-skill-targets.mjs).
// Run: node assets/compile-skill-targets.test.mjs
// Focus: twitch-status-updater#737 — the sentence split must not cut at the
// period inside common abbreviations ("e.g.", "i.e.", …) or inside a still-open
// "(…" parenthetical.
import { strict as assert } from 'node:assert'
import { deriveDescription } from './compile-skill-targets.mjs'

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

console.log(`\ncompile-skill-targets.test: ALL PASS (${n} tests)`)
