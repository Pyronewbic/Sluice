export const meta = {
  name: 'triage-tests',
  description: 'Run the sluice bats gate suites, cluster the failures by likely shared cause, and spawn one agent per cluster to root-cause and propose a fix (does not apply it).',
  whenToUse: 'When the bats suites are red and you want failures grouped and root-caused in parallel rather than read one at a time.',
  phases: [
    { title: 'Run' },
    { title: 'Cluster' },
    { title: 'Root-cause' },
    { title: 'Verify' },
  ],
}

// args.suite (optional): a specific .bats path or glob to run instead of the full gate suite.
// e.g. Workflow({ name: 'triage-tests', args: { suite: 'test/verify-security-dns.bats' } })

const FAILURES_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['passed', 'failures'],
  properties: {
    passed: { type: 'boolean' },
    failures: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['test', 'file', 'message'],
        properties: {
          test: { type: 'string' },
          file: { type: 'string', description: 'the .bats file' },
          message: { type: 'string', description: 'the assertion / error excerpt' },
        },
      },
    },
  },
}

const CLUSTER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clusters'],
  properties: {
    clusters: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['label', 'tests', 'hypothesis'],
        properties: {
          label: { type: 'string' },
          tests: { type: 'array', items: { type: 'string' } },
          hypothesis: { type: 'string' },
        },
      },
    },
  },
}

const ROOTCAUSE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['cluster', 'rootCause', 'fix', 'confidence'],
  properties: {
    cluster: { type: 'string' },
    rootCause: { type: 'string' },
    fix: { type: 'string', description: 'concrete proposed change with file:line' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
}

// A root cause is a CLAIM until someone re-derives it. Acting on a plausible-but-wrong diagnosis means
// editing the wrong file, or - worse here - rewriting a test to agree with broken code, which CLAUDE.md
// names as how a broken `ls` shipped green. Every other workflow in this dir verifies; this one did not.
const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['holds', 'why'],
  properties: {
    holds: { type: 'boolean', description: 'true only if you independently reproduced the causal link' },
    why: { type: 'string', description: 'what you ran/read and what you found' },
    correction: { type: 'string', description: 'the corrected root cause, if the original was wrong' },
    test_is_the_bug: { type: 'boolean', description: 'true if the TEST is wrong rather than the code - flag loudly, never silently rewrite a test to pass' },
  },
}

phase('Run')
const suite = args && args.suite ? args.suite : null
const cmd = suite ? `test/bats/bin/bats --print-output-on-failure ${suite}` : 'make test'
log(`Running ${suite ? suite : 'the gate suites (make test)'}`)

const run = await agent(`Run the sluice bats suites and report failures.
Command: ${cmd}
Note: the acceptance and verify-security suites need a working Docker engine; if Docker is unavailable, report that as the failure rather than guessing. Parse the bats output and return each failing test with its .bats file and the assertion/error excerpt. If everything passes, set passed=true and failures=[].`,
  { label: 'run-suites', phase: 'Run', schema: FAILURES_SCHEMA })

if (!run) return { passed: false, error: 'run-suites agent died - no result' }
if (run.passed) {
  log('All suites passed - nothing to triage')
  return { passed: true, failures: [] }
}
// Not green AND no parseable failures is an error, not a pass - never report false green.
if (!run.failures.length) {
  log('Run was not green but produced no parseable failures - inspect manually')
  return { passed: false, error: 'suite run produced no parseable failures' }
}

phase('Cluster')
log(`${run.failures.length} failing tests - clustering by likely shared cause`)
const clustered = await agent(`Here are the failing bats tests:
${JSON.stringify(run.failures, null, 2)}
Group them into clusters that likely share a single root cause (same suite, same error signature, same subsystem). Give each cluster a short label and a one-line hypothesis. A failure can belong to only one cluster.`,
  { label: 'cluster', phase: 'Cluster', schema: CLUSTER_SCHEMA })

if (!clustered) return { failures: run.failures, diagnoses: [], error: 'cluster agent died' }

phase('Root-cause')
// Hand each root-cause agent the file + assertion excerpts already collected in Run -
// without them every agent re-derives evidence the workflow already has.
const diagnoses = await parallel((clustered.clusters || []).map(c => () => {
  const evidence = run.failures.filter(f => c.tests.includes(f.test))
  return agent(`Root-cause this cluster of failing sluice bats tests and propose a concrete fix. Do NOT apply it.
Cluster: ${c.label}
Hypothesis: ${c.hypothesis}
Failures (test, .bats file, assertion/error excerpt):
${JSON.stringify(evidence.length ? evidence : c.tests, null, 2)}
Read the named .bats files under test/ and the relevant src/*.sh slices (bin/sluice is generated from src/ via 'make build', so fixes go in the slices). Find the actual cause and propose a specific change with a file:line.`,
    { label: `rootcause:${c.label}`, phase: 'Root-cause', schema: ROOTCAUSE_SCHEMA })
}))

phase('Verify')
const found = diagnoses.filter(Boolean)
log(`${found.length} diagnosis/es - re-deriving each independently before it is acted on`)

const checked = await parallel(found.map(d => () =>
  agent(`You are an independent SKEPTIC. Another agent diagnosed a cluster of failing sluice bats tests.
Your job is to REFUTE the diagnosis. Default to holds=false when you cannot independently reproduce it.

CLAIMED ROOT CAUSE: ${d.rootCause}
PROPOSED FIX: ${d.fix}
CLUSTER: ${d.cluster}

Do NOT trust the claim. Re-derive it yourself:
- Read the named .bats files and the relevant src/*.sh slices. Run the failing test and read its FULL
  output, not a tail.
- Establish the CAUSAL link, not a correlation: would the proposed fix actually make these tests pass,
  and does the claimed cause actually produce this failure signature? Prove it - e.g. apply the change
  in a scratch copy, or revert the suspect line and watch the signature change.
- Check the failure is not environmental (Docker down, a missing hasher, a stale bin/sluice out of sync
  with src/ - 'make build-check'), which would make the whole diagnosis moot.
- Decide whether the TEST or the CODE is wrong. If the test encodes the correct contract and the code
  broke it, say so - a test that fails after a refactor is evidence about the contract, and rewriting
  it to agree with new code is how a real regression ships green. Set test_is_the_bug accordingly.
- If the fix would touch bin/sluice directly, that is wrong by construction: it is generated from src/.`,
    { label: `verify:${d.cluster}`, phase: 'Verify', schema: VERDICT_SCHEMA })
      .then(v => ({ ...d, verdict: v }))))

const results = checked.filter(Boolean)
const confirmed = results.filter(r => r.verdict?.holds)
const refuted = results.filter(r => !r.verdict?.holds)
log(`${confirmed.length}/${results.length} diagnoses survived; ${refuted.length} refuted`)

return {
  failures: run.failures,
  diagnoses: confirmed,
  refuted,
  test_is_the_bug: confirmed.filter(r => r.verdict?.test_is_the_bug).map(r => r.cluster),
}
