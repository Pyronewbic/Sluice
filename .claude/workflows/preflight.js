export const meta = {
  name: 'preflight',
  description: 'Ship-readiness gate for a sluice branch: runs the house pre-merge checklist (bin/sluice in sync, shellcheck, unit lane, commit hygiene, lane registration), judges the diff for missing tests / THREAT_MODEL + doc drift, adversarially verifies each blocker, and folds in review-launcher when the launcher changed. Output only - never pushes or merges.',
  whenToUse: 'Before pushing a branch or asking for a merge, to confirm the change follows the contribution contract (CONTRIBUTING.md + CLAUDE.md). Pass a base ref as args (default "main").',
  phases: [
    { title: 'Gate' },
    { title: 'Judge' },
    { title: 'Verify' },
    { title: 'Launcher' },
  ],
}

// The sluice ship loop, codified: branch off main -> edit src/*.sh slices (never bin/sluice) -> make
// build -> local gate -> review -> commit AS the maintainer (no AI author/trailers) -> PR -> 5 required
// CI checks -> squash-merge on sign-off. This workflow is the pre-push half: it REPORTS readiness, it
// does not act. Engine/security Docker lanes are left to CI (too slow for a gate) but flagged when due.

const base = (typeof args === 'string' && args.trim()) ? args.trim()
  : (args && typeof args.base === 'string' && args.base) ? args.base
  : 'main'

const GATE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['checks', 'src_or_core_touched', 'engine_lanes_due', 'new_test_files', 'security_path_touched'],
  properties: {
    checks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'status', 'evidence'],
        properties: {
          name: { type: 'string' },
          status: { type: 'string', enum: ['pass', 'fail', 'skip'] },
          evidence: { type: 'string', description: 'the command output or reason, one line' },
        },
      },
    },
    src_or_core_touched: { type: 'boolean', description: 'diff touches src/*.sh or core/* (launcher review is warranted)' },
    engine_lanes_due: { type: 'boolean', description: 'diff touches engine/security behavior (core/*, firewall, entrypoint, security bats) so the Docker lanes must run in CI' },
    new_test_files: { type: 'array', items: { type: 'string' }, description: 'test/*.bats files ADDED in this diff' },
    security_path_touched: { type: 'boolean', description: 'diff touches a security path (egress, receipts, freshness/staleness gates, policy, the firewall, release verification) or refactors a hot helper - the attack-changes workflow is warranted' },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'file', 'kind', 'detail'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string', description: 'path:line the gap lives at (or the doc that should have changed)' },
          kind: { type: 'string', enum: ['blocker', 'warning'], description: 'blocker = violates the contribution contract; warning = should fix but not gating' },
          detail: { type: 'string' },
          suggestion: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['isReal', 'reason'],
  properties: {
    isReal: { type: 'boolean' },
    reason: { type: 'string', description: 'the diff/source evidence you personally checked' },
  },
}

// House rules the diff is judged against (from CONTRIBUTING.md + CLAUDE.md). Each dimension reads the
// real diff (`git diff <base>...HEAD`) and the touched files - never assumes.
const DIMENSIONS = [
  {
    key: 'commit-hygiene',
    prompt: `Judge the COMMITS on this branch against the sluice contribution contract. Run \`git log ${base}..HEAD --format='%H%x09%an <%ae>%x09%s'\` and \`git log ${base}..HEAD --format=%B\`.
Flag as a BLOCKER: any commit NOT authored 'Kanishka Nambiar <36982731+Pyronewbic@users.noreply.github.com>' (commits must be the maintainer, never an AI author); any 'Co-Authored-By' or 'Signed-off-by: Claude'/AI trailer; a subject that is not a Conventional Commit (feat/fix/security/ci/test/docs/chore, optional scope). Flag as a WARNING: a commit that bundles more than one independently-revertable concern (main squash-merges, but a messy branch history still reads badly).
Return findings with the commit hash in \`file\`.`,
    verifyContext: `The contract: commits authored as the maintainer Pyronewbic ONLY, zero AI author/Co-Authored-By trailers (global CLAUDE.md forbids them), Conventional Commit subjects, one concern per commit. A finding is real only if the actual git metadata violates this.`,
  },
  {
    key: 'test-coverage',
    prompt: `Judge whether this diff ships the TESTS the sluice contract requires. Read \`git diff ${base}...HEAD\`.
Rules: a behavior change to src/*.sh or core/* must extend or add the matching \`test/verify-*.bats\` in the SAME diff. A new knob (SLUICE_* env var or a new flag) ships the full set: a commented stub in sluice.config.example.sh, an entry in docs/configuration.md, a README knob-table row if it is headline, and a \`verify-<knob>.bats\` gate suite (a security knob uses \`verify-security-<knob>.bats\`, which the Makefile SECURITY glob auto-picks-up; a non-security suite must be added to UNIT_BATS explicitly). A new test/*.bats file must be registered in a Makefile lane (verify-lane-membership-unit enforces this - if it is missing, that suite would fail, but flag the omission directly too).
Flag missing tests as BLOCKER, missing config-stub/docs-row as WARNING. Return findings anchored at the src/core line whose behavior is untested.`,
    verifyContext: `The rule is in CONTRIBUTING.md ("a new knob PR ships the full set") and CLAUDE.md ("Behavior change => extend or add the matching verify-*.bats"). A finding is real only if a genuinely new behavior/knob in THIS diff lacks its test. Do not demand tests for pure refactors, docs, or CI-only changes.`,
  },
  {
    key: 'threat-model-sync',
    prompt: `Judge whether a changed GUARANTEE is reflected in THREAT_MODEL.md. Read \`git diff ${base}...HEAD\`.
CLAUDE.md rule: when a change adds, strengthens, or weakens a stated security guarantee, THREAT_MODEL.md (the source of truth) must be updated AND a regression test added in the same change. docs/hardening.md is how-to only - a guarantee change there without a THREAT_MODEL edit is drift.
Flag as BLOCKER: a src/core change that alters egress/firewall/mask/signing/pinning posture with no THREAT_MODEL.md edit in the diff. Return findings anchored at the code line that changed the guarantee.`,
    verifyContext: `THREAT_MODEL.md is the single source of truth for guarantees (per CLAUDE.md + the repo's own rule). A finding is real only if the diff genuinely changes a stated guarantee (not just internals) yet THREAT_MODEL.md is untouched.`,
  },
  {
    key: 'doc-drift',
    prompt: `Judge whether the docs still match behavior after this diff. Read \`git diff ${base}...HEAD\` and the docs it should have touched (README.md, docs/*.md, completion/*, sluice.config.example.sh, EXTENDING.md).
Flag as WARNING (or BLOCKER if it misleads a security decision): a new/renamed flag or knob not reflected in docs/configuration.md; a changed default the docs still state the old value for; a CLI surface change not mirrored in completion/ or README examples; a removed knob still documented. Verify each claim against the actual code in the diff.
Return findings anchored at the doc line that is now wrong (or the code line whose doc is missing).`,
    verifyContext: `Docs are a single source of truth per file (global rule: no duplication, link don't restate). A finding is real only if a doc statement now contradicts the code in this diff, or a documented-surface change left a doc stale.`,
  },
  {
    key: 'generated-artifact',
    prompt: `Confirm the GENERATED launcher is in sync and hand-edit-free. bin/sluice is \`cat src/*.sh\` in lexical order via \`make build\` - it must never be hand-edited, and the slice + regenerated bin ship together.
Run \`make build-check\` (or diff bin/sluice against a fresh \`cat src/00-prelude.sh ...\`) and inspect \`git diff ${base}...HEAD -- bin/sluice src/*.sh\`: if src slices changed but bin/sluice is out of sync -> BLOCKER; if bin/sluice was edited without the corresponding src slice change (a hand-edit) -> BLOCKER. Also scan the src diff for bash-4+ constructs that break the 3.2 floor (associative arrays, \${var^^}/\${var,,}, mapfile/readarray, a \`case\`-')' inside \$(...)).
Return findings anchored at the offending line.`,
    verifyContext: `bin/sluice is generated (cat src/*.sh); make build-check gates sync in CI. bash 3.2 is the floor (macOS /bin/bash). A finding is real only if bin<->src is genuinely desynced, bin was hand-edited, or a real bash-4+ construct entered a slice.`,
  },
]

phase('Gate')
log(`Preflight vs ${base}: running the house gate + judging the diff`)

const gate = await agent(
  `You are running the sluice pre-merge GATE on the current branch (compared to ${base}). You have Bash. Run each check and report status truthfully - do NOT claim pass without running it.
Checks:
1. "bin/sluice in sync" - run \`make build-check\`; pass iff it reports in sync.
2. "shellcheck" - run \`make lint\`; pass iff clean.
3. "unit lane" - run \`make test-unit\`; pass iff all tests ok (this lane also runs verify-lane-membership-unit, so a passing lane means new suites are registered).
4. "maintainer author" - \`git log ${base}..HEAD --format='%an <%ae>'\` are ALL 'Kanishka Nambiar <36982731+Pyronewbic@users.noreply.github.com>'; and \`git log ${base}..HEAD --format=%B | grep -c 'Co-Authored-By'\` is 0. pass iff both.
Then determine: does the diff (\`git diff --name-only ${base}...HEAD\`) touch src/*.sh or core/* (src_or_core_touched)? Does it touch core/*, the firewall/entrypoint, or verify-security-*.bats such that the Docker engine/security lanes must run in CI (engine_lanes_due)? Which test/*.bats files are ADDED (git diff --name-status --diff-filter=A ${base}...HEAD -- 'test/*.bats')? Does it touch a SECURITY PATH - egress, receipts, freshness/staleness gates, policy, the firewall, release verification - or refactor a hot helper shared by several call sites (security_path_touched)? Judge that from what the changed lines DO, not from the filename alone.
Do NOT run the Docker lanes (make test-engine/-security/structure) - they are CI's job; just report engine_lanes_due so the human runs them. Return the structured result.`,
  { label: 'gate', phase: 'Gate', schema: GATE_SCHEMA }
)

phase('Judge')

// Judge each contract dimension, then verify its findings as soon as that dimension finishes (pipeline,
// no barrier) - refute-by-default so a plausible-but-wrong gap doesn't block a ship.
const judged = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `judge:${d.key}`, phase: 'Judge', schema: FINDINGS_SCHEMA }),
  (res, d) => {
    if (!res) { log(`judge:${d.key} returned null - dimension skipped`); return [] }
    return parallel((res.findings || []).map(f => () =>
      agent(`You are a skeptical reviewer. Try to REFUTE this ship-readiness finding about the current sluice branch. Read the actual diff (\`git diff ${base}...HEAD\`) and the cited file. Default to isReal=false unless the contract is genuinely violated.
Context: ${d.verifyContext}

Finding: ${f.title}
Location: ${f.file}
Kind: ${f.kind}
Detail: ${f.detail}`,
        { label: `verify:${d.key}:${f.file}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then(v => ({ ...f, dimension: d.key, verdict: v }))))
  },
)

const all = judged.flat().filter(Boolean)
const confirmed = all.filter(f => f.verdict && f.verdict.isReal)
const unverified = all.filter(f => !f.verdict) // dead verifier != refutation
const gateFails = (gate?.checks || []).filter(c => c.status === 'fail')

// Fold the failed gate checks into the blocker set so the report is one go/no-go list.
const blockers = [
  ...gateFails.map(c => ({ title: `gate: ${c.name}`, file: 'make', kind: 'blocker', detail: c.evidence, dimension: 'gate' })),
  ...confirmed.filter(f => f.kind === 'blocker'),
]
const warnings = confirmed.filter(f => f.kind === 'warning')

// Compose the deep launcher review only when the launcher actually changed - otherwise skip the ~dozen agents.
let launcher_review = null
phase('Launcher')
if (gate?.src_or_core_touched) {
  log('src/*.sh or core/* changed - running review-launcher for the deep security/bash-3.2/portability pass')
  try {
    launcher_review = await workflow('review-launcher', `Preflight-scoped review of the diff vs ${base}.`)
    for (const f of (launcher_review?.confirmed || [])) {
      blockers.push({ title: `launcher: ${f.title}`, file: f.file, kind: 'blocker', detail: f.detail, dimension: `launcher:${f.dimension}` })
    }
  } catch (e) {
    log(`review-launcher could not run (${e && e.message ? e.message : e}) - run it manually before merge`)
  }
} else {
  log('no src/core changes - skipping the launcher review')
}

// Recommend the adversarial pass rather than invoking it: attack-changes runs ~20 agents for ~20
// minutes, an order of magnitude past this gate's cost, and CLAUDE.md only warrants it on a security
// path. Escalating silently would hide that spend inside a check people run on every branch.
const attack_recommended = !!gate?.security_path_touched
if (attack_recommended) {
  log(`security-path change vs ${base} - run the attack-changes workflow before the PR (a green suite only covers the path you exercised)`)
}

const rank = { blocker: 0, warning: 1 }
blockers.sort((a, b) => (rank[a.kind] ?? 2) - (rank[b.kind] ?? 2))

const verdict = blockers.length === 0 ? 'READY' : 'NOT-READY'
log(`preflight: ${verdict} - ${blockers.length} blocker(s), ${warnings.length} warning(s)${gate?.engine_lanes_due ? '; Docker engine/security lanes DUE in CI' : ''}`)

return {
  verdict,
  base,
  gate: gate?.checks || [],
  engine_lanes_due: !!gate?.engine_lanes_due,
  attack_recommended,
  blockers,
  warnings,
  unverified,
  launcher_review,
}
