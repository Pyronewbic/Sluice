export const meta = {
  name: 'demo-beats',
  description: 'Design the VHS tape beats for what has shipped: inventory user-visible capabilities since a tag, score each for what a GIF proves that prose cannot, design a beat for the winners, then have a skeptic try to make each recording pass for the wrong reason. Also ranks the existing GIFs keep/cut/redo against a byte budget.',
  whenToUse: 'After a batch of user-visible work lands (ideally on main), when the demo GIFs no longer show what the tool actually does. Prefer running it on a merged, verified main - beats designed against an unmerged branch can be designed against code that changes in review. Pass args.since (a tag, default the latest) and optionally args.ref / args.include_uncommitted.',
  phases: [
    { title: 'Inventory', detail: 'what shipped, and what the existing demos already show' },
    { title: 'Score', detail: 'three lenses: security story, recordability, coverage gap' },
    { title: 'Design', detail: 'author a concrete beat per surviving capability' },
    { title: 'Break', detail: 'skeptic tries to make each beat record green while proving nothing' },
    { title: 'Choose', detail: 'ranked set, byte budget, recording order' },
  ],
}

// args: a bare tag ("v0.10.0"), or { since?, ref?, focus?, include_uncommitted? }. Tolerate all forms -
// preflight.js does the same; parsing unconditionally would throw on the bare-string invocation.
const A = (typeof args === 'string' && args.trim())
  ? (args.trim().startsWith('{') ? JSON.parse(args) : { since: args.trim() })
  : (args || {})
const SINCE = A.since || ''          // empty => the inventory agent resolves the latest tag itself
const REF = A.ref || 'main'          // prefer main: beats should describe shipped behaviour
const FOCUS = A.focus || ''
const UNCOMMITTED = A.include_uncommitted === true

const HOUSE = `
REPO: /Users/knambiar/Code/OSS/sluice - a POSIX-shell CLI that sandboxes untrusted code in a container.
You are designing VHS tape demos: sources in assets/demos/*.tape (+ a companion *.config.sh), rendered
to assets/*.gif and embedded in README.md / docs/*.md.

HARD CONSTRAINTS:
1. NEVER frame a capability as a response to a named third party, company, product or incident. No
   "in response to X", no company named as the threat or as the reason a feature exists. Every demo
   presents standalone hardening. Real hostnames inside a technical scenario are expected and fine
   (api.anthropic.com, httpbin.org) - that is a different thing from naming a company as the villain.
2. Read before claiming. Read the .tape sources, their .config.sh companions, and the implementing
   slice in src/*.sh. A claim you did not verify by reading is worthless here.
3. House style is set by the existing tapes. Read assets/demos/hard-cap-demo.tape,
   npm-supply-chain.tape and policy-refusal.tape before proposing anything. Each carries a "Reproduce"
   header comment that seeds its own fixture inline; only fleet-audit uses a separate seed script, and
   only because it hand-builds a hash chain with no engine.
4. A demo that animates static text is LOW value - that belongs in a fenced code block. HIGH value is
   the viewer watching something get caught, bounded or refused in real time, where prose alone would
   not be believed.
5. Every GIF costs bytes in every clone. A new beat must earn ~250 KB.

THE TRAP THAT KILLS BEATS - internalise this:
A proposed laundering tape was once rejected because \`resolve_engine\` runs ~725 lines BEFORE
\`warn_laundering\`. With no container engine on PATH the command dies early with "no container engine
found" - and because \`die\` also exits 1, a tape asserting \`|| echo "refused (exit $?)"\` STILL PRINTS
ITS SUCCESS LINE. The recording looks correct and proves nothing. Every beat you propose or judge must
be checked against this: could this shot render identically if the feature were absent, or if the
command failed for an unrelated reason?

YOUR OUTPUT IS DATA, not prose for a human. Return only the requested structure.
`

const SCOPE_NOTE = `
Scope for this run:
- Compare ref: ${REF}${SINCE ? `, changes since tag ${SINCE}` : ', changes since the most recent tag (resolve it yourself with `git describe --tags --abbrev=0`)'}
- ${UNCOMMITTED ? 'INCLUDE uncommitted working-tree changes and unmerged local branches, but LABEL each capability with whether it is merged, branch-only, or uncommitted - an unmerged capability may still change before it ships.' : 'Only capabilities present on ' + REF + '. Do not propose a beat for work that is not merged; note it as deferred instead.'}
${FOCUS ? `- Focus area: ${FOCUS}` : ''}
`

const INVENTORY_SCHEMA = {
  type: 'object',
  properties: {
    since_tag: { type: 'string' },
    capabilities: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'short kebab-case slug' },
          commit: { type: 'string' },
          summary: { type: 'string', description: 'what a USER can now do or is now protected from' },
          user_visible: { type: 'boolean', description: 'false for pure perf/portability/internal work' },
          knobs: { type: 'string', description: 'env knobs / flags / output strings it introduces' },
          slice: { type: 'string', description: 'implementing src/*.sh file and function' },
          merge_state: { type: 'string', enum: ['merged', 'branch-only', 'uncommitted'] },
        },
        required: ['id', 'commit', 'summary', 'user_visible', 'slice', 'merge_state'],
      },
    },
    existing_demos: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          bytes: { type: 'integer' },
          references: { type: 'integer', description: 'how many markdown files embed it' },
          proves: { type: 'string' },
          has_gif: { type: 'boolean' },
        },
        required: ['name', 'bytes', 'references', 'proves', 'has_gif'],
      },
    },
  },
  required: ['capabilities', 'existing_demos'],
}

const SCORE_SCHEMA = {
  type: 'object',
  properties: {
    scored: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          demo_value: { type: 'integer', minimum: 1, maximum: 10 },
          recordable: { type: 'boolean' },
          risk: { type: 'string', description: 'what would make the recording flaky, non-deterministic or vacuous' },
          verdict: { type: 'string', enum: ['author-a-beat', 'fold-into-another-beat', 'prose-only'] },
          rationale: { type: 'string' },
        },
        required: ['id', 'demo_value', 'recordable', 'verdict', 'rationale'],
      },
    },
  },
  required: ['scored'],
}

const BEAT_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    title: { type: 'string' },
    tape_filename: { type: 'string' },
    needs_config_sh: { type: 'boolean' },
    needs_seed_script: { type: 'boolean' },
    scenario: { type: 'string', description: 'the story, and why it is believable rather than contrived' },
    shots: { type: 'array', items: { type: 'string' }, description: 'ordered beats, each naming exactly what appears on screen' },
    payoff: { type: 'string', description: 'the single frame that makes the point' },
    proves: { type: 'string' },
    cannot_pass_vacuously: { type: 'string', description: 'why this could NOT render identically with the feature absent' },
    alt_text: { type: 'string', description: 'house style: long, specific, narrates the whole beat including colours and exit codes' },
    embed_at: { type: 'string', description: 'exact file and section' },
    est_bytes: { type: 'integer' },
  },
  required: ['id', 'title', 'tape_filename', 'scenario', 'shots', 'payoff', 'proves', 'cannot_pass_vacuously', 'alt_text', 'embed_at', 'est_bytes'],
}

phase('Inventory')
log(`Inventorying ${REF}${SINCE ? ` since ${SINCE}` : ' since its latest tag'}`)

const inv = await agent(`${HOUSE}${SCOPE_NOTE}

TASK: Build the inventory this run will work from. Two halves.

(a) CAPABILITIES. Run \`git log ${SINCE ? SINCE + '..' : ''}${REF} --oneline --no-merges\` and read each
commit that could plausibly change what a user sees. For each, read the implementing slice in src/*.sh
to learn what it ACTUALLY does - exact knob names, defaults, output strings, exit codes. Mark
user_visible=false for pure perf, portability and internal work (an awk locale fix has no frame to
show), but still list it so the scoring lenses can disagree with you.

(b) EXISTING DEMOS. List every assets/demos/*.tape and every assets/*.gif. For each: its byte size
(\`ls -la\`), how many markdown files embed it (\`grep -rn '<name>.gif' --include='*.md' .\`), and what
security claim it proves. Note any tape with no rendered GIF, and any GIF whose content has gone stale
against current behaviour.`,
  { label: 'inventory', phase: 'Inventory', schema: INVENTORY_SCHEMA })

const caps = (inv?.capabilities || [])
const demos = (inv?.existing_demos || [])
log(`${caps.length} capabilities (${caps.filter((c) => c.user_visible).length} user-visible), ${demos.length} existing demos`)

phase('Score')

const LENSES = [
  { key: 'security-story', angle: 'Score purely on SECURITY STORYTELLING: which of these, seen in motion, changes what a skeptical reader believes the tool actually does? Weight most heavily the cases a reader would assume CANNOT be caught - a permitted host still being flagged, a refusal that happens before anything is built, a protection that visibly does not cover everything.' },
  { key: 'recordability', angle: 'Score purely on RECORDABILITY: for each capability work out concretely how it would be recorded with docker + vhs, deterministically, on a laptop. Which need a live box, which need a real network fetch, which can be seeded offline, which cannot be made deterministic at all. Name the specific failure modes - container name collisions, the box chowning its mount to uid 1000 after run 1, host ordering in the receipt, timestamps.' },
  { key: 'coverage-gap', angle: 'Score purely on COVERAGE GAP versus the existing demos. Read every existing .tape first. Which capability has NO visual representation at all, and which would merely restate a story an existing GIF already tells better? A capability already well covered scores low however important it is.' },
]

const scored = await parallel(LENSES.map((l) => () =>
  agent(`${HOUSE}${SCOPE_NOTE}

INVENTORY:
${JSON.stringify({ capabilities: caps, existing_demos: demos }, null, 2)}

TASK: ${l.angle}

Score EVERY capability in the inventory, including ones marked user_visible=false - the inventory agent
may have been wrong. Do not defer to it.`,
    { label: `score:${l.key}`, phase: 'Score', schema: SCORE_SCHEMA })))

const allScored = scored.filter(Boolean).flatMap((s) => s.scored)
log(`${allScored.length} scores across ${LENSES.length} lenses`)

// Genuine barrier: choosing the shortlist needs every lens's view of every capability at once.
const shortlist = await agent(`${HOUSE}${SCOPE_NOTE}

INVENTORY:
${JSON.stringify({ capabilities: caps, existing_demos: demos }, null, 2)}

Three independent lenses scored every capability:
${JSON.stringify(allScored, null, 2)}

Pick the capabilities that each deserve their OWN tape beat. Rules:
- A capability survives only if it scores well on security story AND is genuinely recordable AND fills
  a real coverage gap. High value but unrecordable => prose-only, not a beat.
- Prefer FEWER, better beats. Each costs ~250 KB in every clone.
- Where two capabilities share one believable scenario, FOLD them into a single beat.
- Where the lenses DISAGREE sharply about a capability, say so and pick a side with an argument. A
  capability dropped without an argument against it is the failure mode this step exists to prevent.

Return ONLY a JSON array: [{id, capability, why_it_survives, folds_in: [ids], lens_disagreement}].
Ordered by priority.`,
  { label: 'shortlist', phase: 'Score', effort: 'high' })

let picks
try { picks = JSON.parse(shortlist.trim().replace(/^```(?:json)?/, '').replace(/```$/, '').trim()) } catch { picks = [] }
if (!Array.isArray(picks) || !picks.length) {
  log('shortlist did not parse as an array - falling back to the highest-scoring author-a-beat entries')
  const best = {}
  for (const s of allScored.filter((x) => x.verdict === 'author-a-beat')) {
    if (!best[s.id] || s.demo_value > best[s.id].demo_value) best[s.id] = s
  }
  picks = Object.values(best).sort((a, b) => b.demo_value - a.demo_value).slice(0, 3)
}
log(`shortlist: ${picks.length} beat(s) - ${picks.map((p) => p.id).join(', ')}`)

phase('Design')

// Pipeline, not a barrier: each beat is designed then immediately attacked, so a slow design does not
// hold up another beat's critique.
const finals = await pipeline(
  picks,
  (p) => agent(`${HOUSE}${SCOPE_NOTE}

Design ONE tape beat for:
${JSON.stringify(p, null, 2)}

Relevant capability detail from the inventory:
${JSON.stringify(caps.filter((c) => c.id === p.id || (p.folds_in || []).includes(c.id)), null, 2)}

FIRST read assets/demos/hard-cap-demo.tape, npm-supply-chain.tape and policy-refusal.tape plus their
.config.sh companions, and read the implementing slice, so every command and every string you put on
screen is one the tool really prints. Then design the beat.

Requirements:
- Every command must actually work, with output you verified by reading the code. Invent nothing.
- Seed the fixture inline in the "Reproduce" header. Propose a separate seed script only if the
  fixture genuinely cannot be built inline.
- cannot_pass_vacuously is the most important field: explain why this recording could NOT look
  identical if the feature were removed or the command failed for an unrelated reason.
- alt_text in house style - read an existing alt in README.md; they are long and narrate the whole
  beat including colours and exit codes.`,
    { label: `design:${p.id}`, phase: 'Design', schema: BEAT_SCHEMA }),

  (beat, p) => beat ? agent(`${HOUSE}

You are a SKEPTIC. Make this proposed recording pass for the WRONG REASON, or show it cannot be
recorded as written. Assume it is flawed.

PROPOSED BEAT:
${JSON.stringify(beat, null, 2)}

Attack concretely, reading the real code:
1. VACUITY: could each shot render identically with the feature absent? Trace what runs BEFORE the
   feature's code in bin/sluice - could an earlier die/exit produce output the tape would accept?
2. REALITY: does every command exist, take those flags, print those strings? Check src/*.sh. Flag
   anything invented.
3. DETERMINISM: would it record identically twice? Network, timestamps, container name collisions,
   uid-1000 chown of the mount after run 1, host ordering in the receipt.
4. FIXTURE: does the seed produce the state the beat assumes? Would it trip an UNRELATED warning on
   camera that contradicts the point being made?
5. FRAMING: does any on-screen text or alt text violate constraint 1?

Return ONLY JSON: {"fatal": bool, "problems": [{"shot": str, "problem": str, "fix": str}],
"revised_beat": <full beat object with fixes applied, or null if unfixable>}`,
    { label: `break:${p.id}`, phase: 'Break' }).then((v) => {
      let parsed = null
      try { parsed = JSON.parse(v.trim().replace(/^```(?:json)?/, '').replace(/```$/, '').trim()) } catch { /* keep original */ }
      return { proposed: beat, critique: parsed }
    }) : null,
)

const done = finals.filter(Boolean)
const survived = done.filter((f) => !f.critique?.fatal)
const killed = done.filter((f) => f.critique?.fatal)
log(`${survived.length} beat(s) survived the skeptic, ${killed.length} killed`)

phase('Choose')

const plan = await agent(`${HOUSE}${SCOPE_NOTE}

EXISTING DEMOS:
${JSON.stringify(demos, null, 2)}

BEATS THAT SURVIVED (with the skeptic's critique and any revision):
${JSON.stringify(survived, null, 2)}

BEATS KILLED AS UNRECORDABLE OR VACUOUS:
${JSON.stringify(killed.map((k) => ({ id: k.proposed?.id, title: k.proposed?.title, why: k.critique?.problems })), null, 2)}

Write the plan:
1. THE SET - tapes to author, priority order. Per beat: filename, one-line story, what it proves,
   embed location, estimated bytes. Use the skeptic's REVISED version where one exists and say what
   the skeptic changed and why - that reasoning is the most valuable output here.
2. KILLED - and the specific mechanism that would have made each record green while proving nothing.
   Concrete enough that nobody re-proposes it in three months.
3. EXISTING GIFs - a KEEP / CUT / REDO call on each, with bytes-per-reference as the tie-break and
   what is lost by each cut. A GIF embedded in several docs is more load-bearing than its size says.
4. BYTE BUDGET - current total, what the cuts and any optimisation save, what the new beats add, and
   the honest net. Do NOT present a net increase as a reduction.
5. RECORDING ORDER - what to record first, what each needs set up (docker build, warm-up run,
   fixtures, a companion .config.sh), and anything blocked on other work landing first.

Be decisive. Name files and sections. No options-menus.`,
  { label: 'final-plan', phase: 'Choose', effort: 'high' })

return {
  ref: REF,
  since: inv?.since_tag || SINCE || '(latest tag)',
  capabilities: caps.length,
  shortlist: picks,
  survived: survived.length,
  killed: killed.length,
  beats: survived,
  plan,
}
