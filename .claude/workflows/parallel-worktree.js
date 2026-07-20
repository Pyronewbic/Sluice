export const meta = {
  name: 'parallel-worktree',
  description: 'Split a multi-part sluice task into disjoint-file streams, implement each in an isolated git worktree in parallel, and verify each is in-scope + green. Reports per-stream branches + a gotcha log; the DRIVER integrates sequentially (the bin/sluice merge driver resolves the generated file), runs the full Linux gate, and ships. Workflow reports, driver ships.',
  whenToUse: 'A task with 2+ INDEPENDENT parts that touch DISJOINT files (e.g. a new agents/*.config.sh preset + a docs-drift fix + a test-gap fill). NOT for changes that share a hot file (one shared helper in a src/*.sh slice, or the same THREAT_MODEL.md section) - the Preflight gate serializes those. sluice is overlap-dense (every slice change regenerates bin/sluice), so use this selectively; the sequential single-branch flow is usually faster for tightly-coupled work.',
  phases: [
    { title: 'Partition', detail: 'plan disjoint-file streams with declared path ownership' },
    { title: 'Preflight', detail: 'assert stream path-sets are disjoint; serialize any that overlap' },
    { title: 'Implement', detail: 'one worktree-isolated agent per parallel stream: code + make build + test-unit + lint + commit (no push/PR)' },
    { title: 'Verify', detail: 'per-stream adversarial check: in-scope, correct' },
  ],
}

// HOUSE PATTERN: like the other workflows here, this REPORTS - it does not integrate or ship. Parallel
// WRITERS are only safe when their file ownership is disjoint, so the Preflight phase is the load-bearing
// safety: it refuses to run two streams in parallel when their declared paths overlap (it serializes the
// loser for the driver). bin/sluice is the one file EVERY slice-touching stream regenerates - it is
// excluded from the overlap check because the committed git merge driver (`make setup`) auto-regenerates
// it at integration. THREAT_MODEL.md is NOT excluded: parallel edits to it genuinely conflict, so two
// streams that both own it are serialized.
//
// args: { task?: string, streams?: [{id, goal, owns:[paths]}], base?: string }  (default base 'main')
//   - task: a description to partition (a planner proposes disjoint streams from the repo).
//   - streams: a pre-made partition (skips the planner). owns = repo-relative path prefixes.

const SHARED_OK = ['bin/sluice']   // generated + merge-driver-resolved, so shared use is not a real overlap

const PARTITION_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['streams'],
  properties: {
    streams: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['id', 'goal', 'owns'],
        properties: {
          id: { type: 'string', description: 'short kebab-case slug' },
          goal: { type: 'string' },
          owns: { type: 'array', items: { type: 'string' }, description: 'repo-relative path prefixes this stream may touch (files or dirs). MUST be disjoint from every other stream; bin/sluice is shared/OK.' },
        },
      },
    },
  },
}

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['id', 'branch', 'sha', 'status', 'files_changed', 'out_of_scope', 'tests', 'summary'],
  properties: {
    id: { type: 'string' },
    branch: { type: 'string' },
    sha: { type: 'string', description: 'HEAD commit SHA on the branch (lets the driver integrate even if the worktree is cleaned up)' },
    status: { type: 'string', enum: ['done', 'failed'] },
    files_changed: { type: 'array', items: { type: 'string' } },
    out_of_scope: { type: 'array', items: { type: 'string' }, description: 'files changed OUTSIDE the owned set - should be empty, or only bin/sluice' },
    tests: { type: 'string', description: 'make build-check + lint + test-unit result' },
    summary: { type: 'string' },
    gotchas: { type: 'array', items: { type: 'string' }, description: 'anything surprising (worktree/submodule/build), for the living runbook' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['id', 'ok', 'in_scope', 'reason'],
  properties: {
    id: { type: 'string' },
    ok: { type: 'boolean', description: 'in_scope AND the diff correctly achieves the goal without an obvious bug' },
    in_scope: { type: 'boolean' },
    reason: { type: 'string' },
  },
}

const BASE = (args && args.base) || 'main'
const TASK = (args && args.task) || null
let streams = (args && args.streams) || null
if (!TASK && !streams) throw new Error('parallel-worktree: pass args.task (a description to partition) and/or args.streams (a pre-made partition)')

// --- Partition -------------------------------------------------------------
phase('Partition')
if (!streams) {
  const p = await agent(
`Partition this sluice task into INDEPENDENT streams that touch DISJOINT files, for parallel implementation in separate git worktrees.

TASK: ${TASK}

Rules:
- Each stream OWNS a set of repo-relative path prefixes (files or dirs) and may touch ONLY those.
- Ownership MUST be disjoint across streams (no two streams share a path) EXCEPT bin/sluice, which every slice-touching stream regenerates (fine - it is merge-driver-resolved).
- Prefer splitting by src/*.sh slice + its matching test/verify-*.bats, by agents/*.config.sh preset, or by doc file. A change to a helper shared across slices is ONE stream, not several. Two streams that both need the same THREAT_MODEL.md section must be one stream (that file does not auto-merge).
- If the task can't be cleanly split into disjoint streams, return a SINGLE stream (the driver runs it sequentially).
Read the repo to ground ownership in real files.`,
    { schema: PARTITION_SCHEMA, phase: 'Partition' })
  streams = (p && p.streams) || []
}
if (!streams.length) throw new Error('parallel-worktree: partition produced no streams')

// --- Preflight overlap gate (deterministic) --------------------------------
phase('Preflight')
function clashOf(a, b) {
  for (const pa of (a || [])) {
    if (SHARED_OK.includes(pa)) continue
    const x = String(pa).replace(/\/+$/, '')
    for (const pb of (b || [])) {
      if (SHARED_OK.includes(pb)) continue
      const y = String(pb).replace(/\/+$/, '')
      if (x === y || x.startsWith(y + '/') || y.startsWith(x + '/')) return `${pa} <> ${pb}`
    }
  }
  return null
}
const parallelStreams = []
const serialized = []
for (const s of streams) {
  let hit = null
  for (const p of parallelStreams) { const c = clashOf(s.owns, p.owns); if (c) { hit = { with: p.id, on: c }; break } }
  if (hit) serialized.push({ ...s, clash: hit }); else parallelStreams.push(s)
}
log(`${parallelStreams.length} disjoint stream(s) go parallel; ${serialized.length} serialized on path overlap`)
for (const s of serialized) log(`  serialize ${s.id}: overlaps ${s.clash.with} on ${s.clash.on}`)
if (!parallelStreams.length) return { base: BASE, parallel: [], serialized, note: 'no disjoint streams - do this sequentially on one branch (the simplest flow)' }

// --- Implement (parallel, worktree-isolated) -------------------------------
phase('Implement')
const impl = await parallel(parallelStreams.map(s => () =>
  agent(
`Implement ONE stream of a larger sluice task, in your ISOLATED git worktree. Commit only - do NOT push, merge, or open a PR.

Stream: ${s.id}
Goal: ${s.goal}
You OWN (touch ONLY these paths, plus bin/sluice): ${(s.owns || []).join(', ')}

Steps:
1. Start clean from ${BASE}: \`git checkout ${BASE} 2>/dev/null || true\`, then \`git checkout -b wt/${s.id}\`. A fresh worktree may lack the bats submodule - if \`make test-unit\` reports bats missing, run \`make setup\` first.
2. Implement the goal, editing ONLY files under your owned paths. House rules: bin/sluice is GENERATED - edit the src/*.sh slice and run \`make build\`, never hand-edit bin/sluice; bash 3.2 only (no assoc arrays / \${var^^}; a case ')' inside $(...) mis-parses at runtime); add/extend a regression test (test/verify-*.bats) for any behavior change and register a NEW unit test in UNIT_BATS; update THREAT_MODEL.md only if a stated guarantee moves; never frame a change as learned from an external vendor incident.
3. Gate locally, all must pass: \`make build-check\` (in sync), \`make lint\`, \`make test-unit\`.
4. Commit on branch wt/${s.id} with a Conventional Commit subject (security:/fix:/feat:/docs:/test:; no Co-Authored-By trailer).

Report: branch (wt/${s.id}), HEAD sha (\`git rev-parse HEAD\`), status, files changed (repo-relative), any files changed OUTSIDE your owned set (should be empty or only bin/sluice), the gate result, a one-line summary, and any gotchas you hit for the runbook.`,
    { label: `impl:${s.id}`, phase: 'Implement', isolation: 'worktree', schema: IMPL_SCHEMA })
    .then(r => (r ? { ...r, goal: s.goal, owns: s.owns } : null))))

const built = impl.filter(Boolean)

// --- Verify (per stream, read-only diff review) ----------------------------
phase('Verify')
const verified = await parallel(built.map(r => () =>
  agent(
`Adversarially verify one stream of a parallel sluice task. Read the branch's diff against ${BASE} and judge scope + correctness - do NOT re-run the suite (the implementer already gated it, and a checkout here would fight the other streams).

Stream ${r.id} - goal: ${r.goal}
Owned paths: ${(r.owns || []).join(', ')}
Branch: ${r.branch}  sha: ${r.sha}
Implementer report: ${JSON.stringify({ status: r.status, files_changed: r.files_changed, out_of_scope: r.out_of_scope, tests: r.tests, summary: r.summary })}

Via \`git diff ${BASE}..${r.branch} --stat\` and reading the changed files:
- in_scope: did it touch ONLY its owned paths (+ bin/sluice)? Any other path fails it.
- correctness: does the diff achieve the goal, with a regression test for any behavior change and no obvious bug, and is bin/sluice in sync with the slices it changed?
ok = in_scope AND correct.`,
    { label: `verify:${r.id}`, phase: 'Verify', schema: VERDICT_SCHEMA })
    .then(v => ({ id: r.id, branch: r.branch, sha: r.sha, goal: r.goal, files_changed: r.files_changed, tests: r.tests, gotchas: r.gotchas || [], verdict: v }))))

const streamsOut = verified.filter(Boolean)
const gotchas = []
for (const r of built) for (const g of (r.gotchas || [])) gotchas.push(`[${r.id}] ${g}`)

return {
  base: BASE,
  parallel: parallelStreams.map(s => s.id),
  serialized: serialized.map(s => ({ id: s.id, clash: s.clash })),
  streams: streamsOut,
  gotchas,
  driver_next: [
    `Integrate the verified stream branches (wt/<id>) onto an integration branch off ${BASE}, one at a time. The bin/sluice merge driver auto-resolves the generated file; resolve any THREAT_MODEL.md section adjacencies by hand.`,
    `Handle 'serialized' streams sequentially on the updated integration branch (each shared a path with a parallel one).`,
    `Run the FULL gate ONCE on the integrated result: make test-unit + the Linux VM run (SLUICE_VM_ACCOUNT=<personal> sluice-vm.sh test) + the relevant security lanes. Disjoint files can still interact - this catches the semantic conflicts per-stream tests miss.`,
    `Open ONE PR (rebase-merge) per the simplest workflow; auto-merge on green.`,
    `Fold any 'gotchas' above into CLAUDE.md or a hook (living runbook) so the next run doesn't re-hit them.`,
  ],
}
