export const meta = {
  name: 'release-audit',
  description: 'Pre-tag release sweep: draft release notes from commits since the last tag, then fan out checkers over version refs, install/brew mechanics, supply-chain doc accuracy, CLI-help drift, and the ROADMAP checklist - every finding adversarially verified. Output only: edits nothing, tags nothing, pushes nothing.',
  whenToUse: 'Before cutting a release tag, to get a verified go/no-go list plus draft Keep-a-Changelog notes and a post-publish checklist.',
  phases: [
    { title: 'Check' },
    { title: 'Verify' },
    { title: 'Synthesize' },
  ],
}

// args: { version: 'v0.9.0' (the tag about to be cut), since: 'v0.8.0' (optional - defaults
// to the latest tag, resolved by the checkers via `git describe --tags --abbrev=0`) }

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['axis', 'findings'],
  properties: {
    axis: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'detail'],
        properties: {
          // blocker = do not tag until fixed; warn = fix-or-acknowledge; info = post-publish action item
          severity: { type: 'string', enum: ['blocker', 'warn', 'info'] },
          detail: { type: 'string', description: 'what is wrong, with file:line or workflow/doc reference' },
          suggestion: { type: 'string' },
        },
      },
    },
    notes: { type: 'string', description: 'axis-specific artifact, e.g. the draft release notes (changelog axis only)' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['status', 'reason'],
  properties: {
    status: { type: 'string', enum: ['confirmed', 'refuted', 'uncertain'] },
    reason: { type: 'string' },
    correction: { type: 'string' },
  },
}

const version = (args && args.version) || '(next - not specified)'
const since = (args && args.since) || ''
const SINCE = since
  ? `Compare against ${since}.`
  : 'Resolve the previous tag yourself: git describe --tags --abbrev=0.'

const CHECKERS = [
  {
    key: 'changelog',
    prompt: `Draft the release notes for sluice ${version}. ${SINCE}
Run: git log <since>..HEAD --oneline --no-merges (direct-to-main commits count - do not rely on PR titles alone). Read the touched areas enough to describe user-visible changes accurately; never invent a change.
Write FULL Keep-a-Changelog format - Added / Changed / Fixed sections plus the GitHub compare link (https://github.com/Pyronewbic/Sluice/compare/<since>...${version}) - in the 'notes' field. Internal-only churn (CI, test refactors) is summarized in one line or omitted.
Findings: anything that makes notes un-draftable (e.g. a commit whose user impact you cannot determine) - severity=warn with the commit hash.`,
  },
  {
    key: 'version-refs',
    prompt: `Check every hardcoded version reference in the sluice repo against the upcoming tag ${version}. ${SINCE}
Known spots: SLUICE_VERSION in src/00-prelude.sh (the not-a-git-checkout fallback; bin/sluice is generated from src/, so the fix goes in the slice), and any "released through vX" style line in ROADMAP.md. Then sweep: grep -rn for the PREVIOUS tag's bare version string across README.md docs/ install.sh src/ - flag stale refs that should move with the release (skip CHANGELOG/history mentions, which are correct as-is).
severity=blocker for a ref that would ship wrong in the tag; warn for docs that merely lag.`,
  },
  {
    key: 'install-brew',
    prompt: `Check the install paths for sluice ${version}. Read install.sh and the release workflow .github/workflows/release.yml.
1. Do install.sh's assumptions (asset names, paths, checksum/signature steps) match what release.yml actually publishes? Verify against the PREVIOUS release's published assets: gh release view --json assets (or the gh api equivalent).
2. The Homebrew tap lives in a SEPARATE repo - from this repo you can only check references to it (README install section, docs). Flag stale tap instructions; emit the tap formula bump itself as severity=info (a post-publish action item, not a pre-tag blocker).`,
  },
  {
    key: 'supply-chain-docs',
    prompt: `Check sluice's signing/supply-chain claims against what CI actually does. Read docs/supply-chain.md, the README's signing/verification mentions, and SECURITY.md if present; compare against .github/workflows/release.yml and .github/workflows/publish-base.yml (cosign signing, SBOM attestation, what is signed with which identity, which registry).
Flag any doc claim the workflows do not implement, and any workflow step the docs do not mention. Signing accuracy is a launch guardrail here: an overstated claim is severity=blocker.`,
  },
  {
    key: 'cli-drift',
    prompt: `Check CLI-surface drift for the sluice release. Run bin/sluice help (and bin/sluice version) and compare the verb list + flags against: README.md's command documentation, docs/*.md, completion/sluice.bash, completion/_sluice.
Flag: a verb/flag in the CLI missing from docs or completions, and a documented verb/flag the CLI no longer has (the worse direction). The CLI surface is frozen additive-only for 1.0, so a REMOVED verb is severity=blocker.`,
  },
  {
    key: 'roadmap',
    prompt: `Check ROADMAP.md's claimed state against the repo for the sluice ${version} release. For each checklist item marked done: spot-check it is actually true in the repo (the named file/feature/test exists and does what the item says). For each item still open: flag it only if the ROADMAP text implies it gates THIS release.
severity=warn for a done-item that is not actually done; info for open items worth a pre-tag look.`,
  },
]

phase('Check')
log(`Release audit for ${version} - fanning out ${CHECKERS.length} checkers`)

// Pipeline: each axis's findings verify as soon as that checker lands.
const results = await pipeline(
  CHECKERS,
  c => agent(c.prompt, { label: `check:${c.key}`, phase: 'Check', schema: FINDINGS_SCHEMA }),
  (check, c) => {
    if (!check) { log(`check:${c.key} returned null - axis skipped`); return { axis: c.key, dead: true, verified: [] } }
    return parallel((check.findings || []).map(f => () =>
      agent(`You are a skeptical verifier. A release-audit checker flagged this on the sluice repo. Try to REFUTE it.

Axis: ${c.key}
Severity: ${f.severity}
Detail: ${f.detail}
Suggestion: ${f.suggestion || '(none)'}

Check every concrete claim against the repo (and gh/upstream where the claim is about a published release). Audits routinely state plausible-but-wrong specifics.
- confirmed ONLY if real and the specifics check out.
- refuted if wrong or already handled.
- uncertain if you cannot verify - default here rather than guessing.
If the direction is right but a specific is wrong, put the corrected value in 'correction'.`,
        { label: `verify:${c.key}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then(v => ({ ...f, axis: c.key, verdict: v }))))
      .then(verified => ({ axis: c.key, notes: check.notes || '', verified: verified.filter(Boolean) }))
  },
)

const axes = results.filter(Boolean)
const allFindings = axes.flatMap(a => a.verified || [])
const confirmed = allFindings.filter(f => f.verdict && f.verdict.status === 'confirmed')
const uncertain = allFindings.filter(f => !f.verdict || f.verdict.status === 'uncertain')
const blockers = confirmed.filter(f => f.severity === 'blocker')
const draftNotes = (axes.find(a => a.axis === 'changelog') || {}).notes || '(changelog checker died - draft notes missing)'
log(`${blockers.length} blockers, ${confirmed.length} confirmed total, ${uncertain.length} uncertain`)

phase('Synthesize')
const report = await agent(`Assemble the release-audit report for sluice ${version}. Plain ASCII markdown, terse - the maintainer knows the repo. Your final message is the report verbatim.

CONFIRMED findings (skeptic-verified; corrections noted):
${JSON.stringify(confirmed, null, 2)}

UNCERTAIN findings (worth a human look):
${JSON.stringify(uncertain, null, 2)}

DRAFT RELEASE NOTES from the changelog checker:
${draftNotes}

Dead/skipped axes: ${JSON.stringify(axes.filter(a => a.dead).map(a => a.axis))}

Structure:
1. Go / no-go: NO-GO iff any blocker stands; list blockers first, then warns, then infos, each with its fix.
2. The draft release notes (lightly edit for accuracy against the confirmed findings; keep full Keep-a-Changelog format with the compare link).
3. Post-publish checklist, in order: publish the DRAFT release as the Pyronewbic account (drafts are not tag-associated until published), bump the separate Homebrew tap repo, plus any severity=info items from above.
Everything is output - state explicitly that nothing was edited, tagged, or pushed.`,
  { label: 'synthesize', phase: 'Synthesize' })

return { report, blockers: blockers.length, confirmed: confirmed.length, uncertain: uncertain.length }
