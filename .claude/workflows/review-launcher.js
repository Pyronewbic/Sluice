export const meta = {
  name: 'review-launcher',
  description: 'Multi-dimension review of the sluice launcher (src/*.sh -> bin/sluice) across security, bash-3.2 correctness, and docker/podman portability; each finding is adversarially verified before it survives.',
  whenToUse: 'Before merging changes to src/*.sh or bin/sluice, or to audit the launcher for egress-bypass / shell-portability bugs.',
  phases: [
    { title: 'Review' },
    { title: 'Verify' },
  ],
}

// bin/sluice is GENERATED from the ordered src/*.sh slices via `make build`. Reviewers read the
// slices (the real source), not the assembled launcher.

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
        required: ['title', 'file', 'severity', 'detail'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string', description: 'path:line, e.g. src/10-egress-helpers.sh:42' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
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
    reason: { type: 'string' },
  },
}

const DIMENSIONS = [
  {
    key: 'security',
    prompt: `Review the sluice launcher for security holes that would let a sandboxed process escape the egress allowlist or firewall.
Read the source slices in src/*.sh (bin/sluice is GENERATED from them - review the slices). Focus on src/10-egress-helpers.sh, src/40-runtime.sh, src/70-build-run.sh, src/50-init.sh.
Look for: allowlist bypass, host/IP laundering, DNS-sink exfil gaps, SLUICE_ALLOW_IPS port-scoping mistakes, SSL-bump misconfig, unquoted expansions that let a hostile config inject flags, anything that weakens the default-DROP egress posture.
Return concrete findings, each with a src/<slice>:line location.`,
  },
  {
    key: 'bash32',
    prompt: `Review the sluice launcher for bash 3.2 correctness. bin/sluice must run under macOS's stock bash 3.2 AND modern Linux bash. Read src/*.sh.
Look for: bash-4+ only constructs (associative arrays, \${var,,}/\${var^^}, |&, mapfile/readarray), a case ')' inside $(...) (mis-parses under 3.2 and 'bash -n' will NOT catch it - the highest-value bug class here), [[ =~ ]] quirks, and 'local x=$(...)' masking the command's exit status.
Return concrete findings, each with a src/<slice>:line location.`,
  },
  {
    key: 'portability',
    prompt: `Review the sluice launcher for docker vs rootless-podman divergence. Read src/*.sh, especially src/40-runtime.sh and the firewall/init path.
Only docker + rootless podman are supported; rootful podman (netavark) is out of scope. Look for: engine-specific flags assumed present on both backends, network/DNS setup that only works on one, sysctl/iptables assumptions, anything that silently no-ops on podman.
Return concrete findings, each with a src/<slice>:line location.`,
  },
]

phase('Review')
log(`Reviewing the launcher across ${DIMENSIONS.length} dimensions`)

// Pipeline: each dimension's findings verify as soon as that dimension finishes reviewing -
// no barrier, so the bash32 verifies don't wait on the slower security review.
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (review, d) => parallel((review.findings || []).map(f => () =>
    agent(`You are a skeptical reviewer. Try to REFUTE this finding about the sluice launcher. Read the cited file and surrounding code. Default to isReal=false unless you can clearly confirm the bug is real and reachable.

Finding: ${f.title}
Location: ${f.file}
Severity: ${f.severity}
Detail: ${f.detail}`,
      { label: `verify:${d.key}:${f.file}`, phase: 'Verify', schema: VERDICT_SCHEMA })
      .then(v => ({ ...f, dimension: d.key, verdict: v })))),
)

const confirmed = results.flat().filter(Boolean).filter(f => f.verdict && f.verdict.isReal)
log(`${confirmed.length} confirmed findings`)
return { confirmed }
