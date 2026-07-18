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

t('falls back to the project-skill stub for a body with no prose', () => {
  assert.equal(deriveDescription('# Only a heading\n', 'my-skill'), 'Project skill: /my-skill')
})

t('a paragraph ending in a bare abbreviation returns whole paragraph (no dangling cut)', () => {
  assert.equal(deriveDescription('Handles common cases e.g.\n', 'x'), 'Handles common cases e.g.')
})

console.log(`\ncompile-skill-targets.test: ALL PASS (${n} tests)`)
