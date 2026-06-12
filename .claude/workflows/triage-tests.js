export const meta = {
  name: 'triage-tests',
  description: 'Run the sluice bats gate suites, cluster the failures by likely shared cause, and spawn one agent per cluster to root-cause and propose a fix (does not apply it).',
  whenToUse: 'When the bats suites are red and you want failures grouped and root-caused in parallel rather than read one at a time.',
  phases: [
    { title: 'Run' },
    { title: 'Cluster' },
    { title: 'Root-cause' },
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

return { failures: run.failures, diagnoses: diagnoses.filter(Boolean) }
