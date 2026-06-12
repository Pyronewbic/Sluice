export const meta = {
  name: 'audit-egress',
  description: 'Audit every agent preset (agents/*.config.sh) for egress drift, then adversarially verify each finding against the real preset + upstream source before reporting it. Findings are leads until a skeptic confirms them.',
  whenToUse: 'Periodically or before a release, to catch agent-preset egress drift before a user hits a blocked host. A deeper one-shot companion to the weekly agents-smoke.yml gate.',
  phases: [
    { title: 'Map' },
    { title: 'Audit' },
    { title: 'Verify' },
  ],
}

const MAP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['presets'],
  properties: {
    presets: {
      type: 'array',
      items: { type: 'string', description: 'preset name without path or .config.sh, e.g. claude' },
    },
  },
}

const AUDIT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['preset', 'declaredHosts', 'issues'],
  properties: {
    preset: { type: 'string' },
    declaredHosts: { type: 'array', items: { type: 'string' } },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['kind', 'detail'],
        properties: {
          kind: {
            type: 'string',
            enum: ['unlisted-host', 'moved-host', 'renamed-pkg', 'removed-binary', 'threat-model-gap', 'other'],
          },
          host: { type: 'string' },
          detail: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['status', 'reason'],
  properties: {
    // confirmed = real AND specifics check out; refuted = wrong / not on this preset's path;
    // uncertain = couldn't verify (the honest default - never upgrade a guess to confirmed).
    status: { type: 'string', enum: ['confirmed', 'refuted', 'uncertain'] },
    reason: { type: 'string' },
    // If the direction is right but a specific is wrong (the lesson from hand-verifying these:
    // audits state plausible-but-wrong flags/hosts/dates), the corrected value goes here.
    correction: { type: 'string' },
  },
}

// Discover presets at run time (not hardcoded) so the audit fans out over whatever is actually in
// agents/ - the point of the workflow is to catch drift, including added/removed presets.
phase('Map')
const map = await agent(`List every agent preset in this repo. Run: ls agents/*.config.sh
Return just the preset names - the filename without the agents/ prefix and without the .config.sh suffix.`,
  { label: 'map-presets', phase: 'Map', schema: MAP_SCHEMA })

const presets = (map && map.presets) || []
if (!presets.length) {
  log('No presets mapped (mapper died or agents/ is empty) - nothing to audit')
  return { confirmed: [], uncertain: [], refuted: [], error: 'no presets mapped' }
}
log(`Auditing ${presets.length} agent presets, then verifying each finding`)

// Pipeline (no barrier): a preset's findings stream into Verify as soon as its audit lands, so the
// fast presets' findings get refuted while the slow presets are still being audited.
const auditPrompt = (p) => `Audit the agent preset agents/${p}.config.sh for egress drift.
1. Read agents/${p}.config.sh. List every host/domain it relies on - SLUICE_ALLOW_DOMAINS plus any hosts implied by its setup/prefetch/run commands and the agent CLI's own API endpoints.
2. The always-on base allowlist (base_domains() in src/10-egress-helpers.sh) is exactly: github.com api.github.com codeload.github.com objects.githubusercontent.com registry.npmjs.org registry.yarnpkg.com - the preset need not re-list those. Note raw.githubusercontent.com is NOT base (it is a known laundering host). Read THREAT_MODEL.md for what the egress posture promises.
3. Flag drift: a host not covered by base+preset allowlist, a host that looks renamed or moved, a package whose registry changed, a binary the preset installs that no longer exists upstream, or an egress need the threat model doesn't account for.
Be concrete - name the host and what's wrong. If the preset is clean, return an empty issues array.`

const verifyPrompt = (preset, issue) => `You are a skeptical verifier. An automated audit flagged this issue on agents/${preset}.config.sh. Your job is to REFUTE it.

Issue kind: ${issue.kind}
Host: ${issue.host || '(none)'}
Detail: ${issue.detail}

Check it against BOTH (a) the actual agents/${preset}.config.sh in this repo, and (b) the real upstream source/docs for that tool - curl the source, npm view the package, fetch the vendor's network doc. Audits routinely state plausible specifics that are WRONG (a flag that doesn't exist, a host that moved, a removal date that's invented), so verify every concrete claim: exact host name, exact package name, exact CLI flag, any date.
- status=confirmed ONLY if the issue is real on this preset's actual run path AND its specifics check out.
- status=refuted if it's wrong, or the host/flag isn't reachable on the path this preset uses.
- status=uncertain if you cannot verify it from source/docs - default here rather than guessing.
If the direction is right but a specific (flag, host, package, date) is wrong, put the corrected value in 'correction'.`

const results = await pipeline(
  presets,
  p => agent(auditPrompt(p), { label: `audit:${p}`, phase: 'Audit', schema: AUDIT_SCHEMA }),
  // Preset name comes from the pipeline item (p), never the agent-echoed audit.preset.
  (audit, p) => {
    if (!audit) { log(`audit:${p} returned null - preset skipped`); return [] }
    return parallel((audit.issues || []).map(issue => () =>
      agent(verifyPrompt(p, issue), {
        label: `verify:${p}:${issue.host || issue.kind}`,
        phase: 'Verify',
        schema: VERDICT_SCHEMA,
      }).then(v => ({ ...issue, preset: p, verdict: v }))))
  },
)

const all = results.flat().filter(Boolean)
const confirmed = all.filter(i => i.verdict && i.verdict.status === 'confirmed')
// A dead verifier (verdict null) is unverified, not refuted - bucket it with uncertain.
const uncertain = all.filter(i => !i.verdict || i.verdict.status === 'uncertain')
const refuted = all.filter(i => i.verdict && i.verdict.status === 'refuted')
log(`${confirmed.length} confirmed, ${uncertain.length} uncertain, ${refuted.length} refuted (of ${all.length} raw findings)`)

// confirmed = act on these; uncertain = worth a human look; refuted dropped from the headline but
// returned so a run is auditable (you can see what the skeptic killed and why).
return { confirmed, uncertain, refuted }
