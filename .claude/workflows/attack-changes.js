export const meta = {
  name: 'attack-changes',
  description: 'Adversarially attack the changes on this branch: scope the diff into attackable areas, run one attacker per area hunting a concrete break with a paste-able repro, then have an independent skeptic re-run every claim and drop anything that is not reproducible or is pre-existing on the base. Finds the defects a green suite does not.',
  whenToUse: 'BEFORE opening a PR, on anything touching a security path (egress, receipts, freshness/staleness gates, release verification, the firewall) or any refactor of a hot helper. A green test suite only covers the path you happened to exercise; this hunts the input nobody constructed. Two rounds of it once found 16 real defects in changes that already had a green lane. Cheap relative to shipping a fail-open gate.',
  phases: [
    { title: 'Scope', detail: 'partition the branch diff into attackable areas' },
    { title: 'Attack', detail: 'one attacker per area: break it with crafted input' },
    { title: 'Confirm', detail: 'independent skeptic re-runs each claimed break' },
  ],
}

// args: a bare base ref ("main"), an object { base?, focus? }, or that object as a JSON string -
// which one arrives depends on the invocation path, so tolerate all three. Parsing unconditionally
// throws on the documented `args: "main"` form before a single agent starts.
const A = (typeof args === 'string' && args.trim())
  ? (args.trim().startsWith('{') ? JSON.parse(args) : { base: args.trim() })
  : (args || {})
const BASE = A.base || 'main'
const FOCUS = A.focus || ''

const SCOPE = {
  type: 'object', additionalProperties: false, required: ['areas'],
  properties: {
    areas: { type: 'array', items: {
      type: 'object', additionalProperties: false, required: ['id', 'what_changed', 'why_attackable'],
      properties: {
        id: { type: 'string', description: 'short kebab-case slug' },
        what_changed: { type: 'string', description: 'the specific behaviour that changed, with file:line' },
        why_attackable: { type: 'string', description: 'the inputs/conditions most likely to break it' },
      },
    } },
  },
}

const FINDINGS = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false, required: ['title', 'severity', 'repro', 'observed', 'expected', 'is_new'],
      properties: {
        title: { type: 'string' },
        severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'nit'] },
        repro: { type: 'string', description: 'exact paste-able commands that trigger it' },
        observed: { type: 'string' }, expected: { type: 'string' },
        is_new: { type: 'boolean', description: 'true if this branch introduced it; false if it also reproduces on the base' },
      },
    } },
  },
}

const VERDICT = {
  type: 'object', additionalProperties: false, required: ['title', 'verdict', 'detail'],
  properties: {
    title: { type: 'string' },
    verdict: { type: 'string', enum: ['CONFIRMED', 'NOT_REPRODUCIBLE', 'WORKS_AS_INTENDED'] },
    detail: { type: 'string' },
  },
}

// The traps that have actually produced false results in this repo. Every agent gets these.
const TRAPS = `KNOWN TRAPS - a result that ignores these is worthless:
- VACUOUS EXECUTION: a function with an early-return guard may never run, so every assertion "passes".
  check_update_notice returns early unless it can derive an X.Y.Z from \`sluice version\`, and
  \`git describe --tags --always\` yields a bare SHA on a tagless checkout (or a stray non-version tag).
  PROVE the code path executes before trusting any negative result.
- SWALLOWED OUTPUT: production sends some stderr to /dev/null, so a message-based tripwire never fires.
  Use a marker FILE.
- \`$(...)\` DISABLES ERREXIT: a failure inside a command substitution is discarded, and an empty result
  can compare equal to an empty expected value - a fail-open gate that looks fine.
- PIPELINE vs PRINTF: a function body ending in a pipeline propagates status under pipefail; one ending
  in printf always returns 0. Refactors silently delete error handling this way.
- Read WHOLE outputs, never a \`tail\` - a truncated list has produced a "green" report on a red run.`

phase('Scope')
const scoped = await agent(
`Scope the changes on this branch for adversarial attack. Repo: a security-focused POSIX-shell CLI that
sandboxes untrusted code; correctness matters more than speed everywhere.

Read the diff against ${BASE}: \`git diff ${BASE}...HEAD\`, \`git log --oneline ${BASE}..HEAD\`, and the
changed files themselves.${FOCUS ? `\n\nThe maintainer wants particular attention on: ${FOCUS}` : ''}

Partition it into attackable AREAS - one per distinct behaviour that changed (not one per file). For each,
state exactly what behaviour changed with file:line, and what inputs or conditions are most likely to break
it. Prioritise: anything on a security path (egress, receipts, freshness/staleness gates, release
verification, the firewall), any refactor of a shared helper, any new parsing or encoding, and anything that
now handles externally-supplied data. If the diff is trivial and genuinely not attackable, return one area
saying so.`,
  { label: 'scope', phase: 'Scope', schema: SCOPE })

const areas = (scoped && scoped.areas) || []
log(`${areas.length} attackable area(s) in ${BASE}..HEAD`)
if (!areas.length) return { areas: 0, confirmed: [], note: 'nothing attackable found in the diff' }

phase('Attack')
const found = await parallel(areas.map(a => () =>
  agent(
`Try to BREAK one area of this branch. You are not reviewing style - you are hunting a concrete failure.

AREA: ${a.id}
WHAT CHANGED: ${a.what_changed}
LIKELY WEAKNESS: ${a.why_attackable}

${TRAPS}

METHOD:
1. Read the new code AND the old (\`git show ${BASE}:<file>\`) so you can tell a REGRESSION from a
   pre-existing condition.
2. Construct the input nobody built: empty/missing/huge values; embedded newline, tab, quote, backslash,
   NUL-adjacent and control bytes (0x1f); a dependency that is absent, broken, or exits non-zero; a
   hostile file where a trusted one is expected (symlink, wrong perms, malformed, truncated, no trailing
   newline); numeric extremes (0, negative, leading zero, 2^31, 2^63); unset HOME/TMPDIR; concurrent runs.
3. RUN it. A finding must include commands someone else can paste to see the failure, plus the real output.
4. Set is_new by actually testing the base: if the same repro fails identically on ${BASE}, it is NOT a
   regression from this branch - say so honestly rather than inflating the count.

If the change genuinely holds up, return an EMPTY findings array. "I could not break it" is a valid and
useful result. Do not pad with nits.`,
    { label: `attack:${a.id}`, phase: 'Attack', schema: FINDINGS })
    .then(r => (r ? (r.findings || []).map(f => ({ ...f, area: a.id })) : []))))

const all = found.flat()
log(`${all.length} candidate break(s); ${all.filter(f => f.is_new).length} claimed as introduced here`)
if (!all.length) return { areas: areas.length, counts: { claimed: 0, confirmed: 0 }, confirmed: [], note: 'no attacker broke the changes' }

phase('Confirm')
const checked = (await parallel(all.map(f => () =>
  agent(
`Independently re-run ONE claimed break. Do NOT trust the report - paste and run the repro yourself.

TITLE: ${f.title}   (area ${f.area}, claimed ${f.severity}, claimed_new=${f.is_new})
REPRO: ${f.repro}
CLAIMED OBSERVED: ${f.observed}
CLAIMED EXPECTED: ${f.expected}

${TRAPS}

Verdicts:
- CONFIRMED - reproduces AND is a real defect in the current code.
- NOT_REPRODUCIBLE - does not reproduce as described (say what actually happened).
- WORKS_AS_INTENDED - reproduces but the behaviour is correct, OR it reproduces identically on ${BASE}
  (\`git show ${BASE}:<file>\`) and so is pre-existing, not a regression. State which, explicitly.

In detail: the real output you saw, whether it is pre-existing, and if CONFIRMED the minimal fix.`,
    { label: `confirm:${f.title}`.slice(0, 55), phase: 'Confirm', schema: VERDICT })
    .then(v => (v ? { ...f, verdict: v } : null))))).filter(Boolean)

const real = checked.filter(r => r.verdict.verdict === 'CONFIRMED')
return {
  base: BASE,
  areas: areas.length,
  counts: { claimed: all.length, confirmed: real.length, regressions: real.filter(r => r.is_new).length },
  confirmed: real.map(r => ({
    area: r.area, title: r.title, severity: r.severity, is_new: r.is_new, repro: r.repro, detail: r.verdict.detail,
  })),
  dismissed: checked.filter(r => r.verdict.verdict !== 'CONFIRMED')
    .map(r => ({ area: r.area, title: r.title, verdict: r.verdict.verdict, why: r.verdict.detail.slice(0, 300) })),
  driver_next: [
    'Fix every CONFIRMED finding, and add the regression test that would have caught it - stub the DEPENDENCY, not the function under test.',
    'Re-run this workflow against the fixes: the fixes are new code and have never been attacked.',
    'A finding marked pre-existing (is_new false) is still real - decide deliberately whether it belongs in this PR or its own.',
  ],
}
