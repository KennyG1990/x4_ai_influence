# BACKLOG — X4 Neural Link + AI Influence (OPEN work only)

> Workflow v2: sessions START here. States: `spec'd` · `in-progress` · `blocked(<on>)` · `watch`.

## ✅ P0 PHASE 0 BASELINE CERTIFICATION SHIPPED → ROADMAP #192 (2026-07-21). VERIFIED with ONE ◐ watch tail:
## the dead-cue WITHDRAW branch hasn't fired naturally yet — flip fully ✅ when a stale withdraw logs
## "withdrawn (cue already dead)" with zero `Error in MD cue` lines. Do NOT rebuild anything here — see #192.

## 🗺️ SPEC-COVERAGE MAP (2026-07-21) — the through-line to "the mod does the docs".
## Full requirement-by-requirement table + risk register: wiki/x4-neural-link/spec-coverage-map.md
## (compiled from all 11 AI Influence - Systems docs). STATUS SUMMARY: the marquee conversation core
## (talk / remember / non-scripted) is PROVEN serverless; MOST other systems are BRIDGE (work today on
## Python, must be re-homed); station-combat + contagion are NONE + engine-risky (spike first).
## CRITICAL PATH (richness-per-unit): P2✅ → P3 (context+backend) → P4 (conversation) → P6 (events/news)
## → P7 (diplomacy core) → P5 (actions) → P8 (loyalty/obituaries) → [spike] P9 contagion → [spike] P10 combat.
## 22-item ENGINE-HOOK RISK REGISTER (R1-R22) gates the greenfield systems — each needs a feasibility spike
## in a throwaway cue BEFORE committing (sector transfer, faction credit accounts, NPC/drone spawn, individual
## NPC death, quarantine undock-block, per-ship stat mod, blueprint grant, TTS playback, DLC detection, …).
## THE NEXT 3 UNITS (map §4), each with a bridge-killed acceptance test:
##   U1 P3-a grounded context — inject real standing + nearby stations/sectors + a live relation into the
##      :4315 prompt from PROVEN reads only (no RoleRAG). Flips ~11 reqs off the bridge.
##   U2 P3-b backend menu — options page for {Player2,OpenRouter,DeepSeek,Ollama,KoboldCpp}+endpoint/model/key,
##      persisted; route SendDirect to the choice; unhardcode the key. (Player enters own key in-game.)
##   U3 ✅ SHIPPED → ROADMAP #197 (2026-07-21). Trust scalar/tiers/tone-driver/gating; selftest 21/21 live.
##      ◐ gating-changes-reply-across-a-tier needs a multi-turn conversation (Ken/fresh session).
## STILL OPEN on the critical path: U2 backend menu · P6 events/news (re-home from bridge) · P7 diplomacy core.

## 🔬 ENGINE FEASIBILITY VERDICT (2026-07-21) — wiki/x4-neural-link/engine-feasibility.md (vanilla-grounded,
## every hook cited file:line against 9.00). DIRECTS P5-P10:
## - P5 TRADE: FEASIBLE, NO SPIKE — reward_player/add_blueprints/add_wares/add_inventory/set_owner all proven.
## - P6 AWARENESS/TOPOLOGY: FEASIBLE, NO SPIKE — gatedistance/adjacentzones/find_gate + DLC detection
##   (player.allmodules.{$macro}.isextensionenabled). Pure reads.
## - P7 DIPLOMACY: CORE + credit term FEASIBLE (set_faction_relation + transfer_money via faction.ownerless);
##   SECTOR-CEDE = flip the claiming station (set_owner on canclaimownership station; SPIKE the map recolor);
##   NEW RUNTIME FACTION = INFEASIBLE → REDESIGN: dormant-faction pool in factions.xml + set_faction_diplomacy_active.
## - P8 RECRUITMENT: functional-FEASIBLE via container.availablepeople + assign_hired_actor/create_npc_from_template.
## - P9 CONTAGION: dock event + crew-kill + markers FEASIBLE; QUARANTINE hook set_player_undocking_locked is
##   schema-legal but ZERO vanilla usages → SPIKE before building (fallback set_object_docking_enabled);
##   COMBAT-DEBUFF = no multiplier exists → compose from set_skill(piloting/gunnery) + set_object_hull/shield
##   + set_weapon_mode as one "infected" status.
## - P10 STATION COMBAT: spawn defenders (create_ship dock= + control entity + create_order Attack) +
##   launch_drone(defence) + per-module destroy_object(explosion) ALL PROVEN; "disable module" = hack-panel
##   state (iscontrolpanelhacked suppresses drone launch — vanilla-proven) or single-module detonation;
##   PLAYER CAPTURE/KNOCKOUT = INFEASIBLE (no hook, grep-negative) → REDESIGN stakes: asset hostage
##   (set_owner seizes ships), undock-lock traps, spacesuit stranding — never the player's body.
## Doc-fidelity note (brief rule "rewrite unsupported requirements rather than fabricating capability"):
## the redesigns above deliver each doc's INTENT with real hooks; docs 04/07 should be annotated accordingly.

- **P7-b `SPECIFIED→in-progress` TRIBUTE/REPARATIONS on ceasefire (doc-03 tribute-daily/reparations-lumpsum,
  deterministic v1):** at the fatigue-ceasefire moment (the branch that logs "agreed to a ceasefire"), count
  both factions' stations (find_station owner= galaxy, one-off) — the SMALLER faction is the deterministic
  war-loser proxy and owes reparations: 3 installments × 300k Cr, minted into Snap ('$w_'+key = remaining
  count + payer/payee), paid ONE installment per pulse tick via the FEASIBILITY-PROVEN
  `<transfer_money from="faction.loser" to="faction.winner" amount=.../>` (vanilla faction-wallet pattern,
  diplomacy.xml:298; add_money does NOT work on factions). Logbook per installment; AIC-STATE gains trib=[…].
  **Acceptance (closed-loop, reuse the proven rig):** forced war + 72s threshold → ceasefire → reparation
  minted with the correct payer (station counts logged) → 3 installments over 3 ticks → obligation cleared;
  ENGINE-STATE proof per the anti-fabrication standard: faction account deltas visible in a before/after
  quicksave parse (faction accounts serialize) or transfer_money result reads. Rig stripped after; guards:
  never player/xenon/khaak.

- **P7-polish RESOLVED by-design 2026-07-21:** fatigue clocking only 'war'-bucket pairs is CORRECT — doc-03
  says factions seek peace from WAR-weariness; 'hostile' (-0.5..-0.125) is a stable resting state, not a war.
  No code change. (The boundary-guard bug was test-rig-only, already fixed.) Kept as a note, not open work.

- **FACTION-ID RESOLVER `spec'd` (unblocks TWO things): get a faction's string id from a component.** Recurring
  blocker: `Offer_contract` needs `faction.{$fid}` (an id string like 'argon'); an arbitrary station's owner is
  a faction COMPONENT with no clean MD id-string accessor (D-A finding: owner.owner=NIL). #204 war contracts
  worked only because the pulse loop HAS the id strings. FIX (one bounded unit): a small resolver that matches
  a component's owner against the known faction id list (iterate $ids, compare owner == faction.{$id}) →
  returns the id string. Unblocks (a) economy shortage → SUPPLY contract from the station's faction, (b) D-A
  persona faction display name, (c) sector-owner reads. Do this BEFORE widening contract sources.

## 🗺️ REMAINING SYSTEMS (honest scope after the core is done — Ken steers priority)
The living-galaxy CORE is done + engine-proven serverless: conversation (docs 01/02), memory/trust/gating,
events + full diplomacy arc incl. reparations (docs 02/03). The remainder splits into 3 buckets:
- **A. LARGE RE-HOMES (work today on the dormant bridge; architecture, multi-unit each):**
  - CONTRACTS/OPORD (`spec'd`, task #14): NOT bookkeeping — it's the DECISION ENGINE. Bridge generated job
    offers from assessed threats + formed OPORDs (~20k lines Python); the mod polls /v1/jobs/offers +
    /v1/opord/orders/pending and materializes them. Re-home = port the assessment→offer→pricing +
    OPORD-formation logic into MD/Lua. BOUNDED FIRST SLICE (buildable, closed-loop): a single deterministic
    contract type minted from the EXISTING MD combat kill-event feed (ai_influence_combat On_killed) — "defend
    <station> under attack" offer via the proven mission-offer framework (aic_contracts already has create_offer
    + accept/abort). Prove: kill event → offer appears → accept → abort/complete → withdraw clean (also
    restores the #202 @? withdraw functional test). Then widen.
  - WAR-INDUSTRY (`spec'd`): losses→build decisions→shipyard placement (W-chain). Bridge-side; re-home later.
- **B. ENGINE-RISKY GREENFIELD (SPIKE first per engine-feasibility.md, then build):**
  - STATION COMBAT (doc 07): spawn-defender + detonate-module FEASIBLE; player-knockout INFEASIBLE (design
    around — player ejects to suit). Needs the R4/R5 spike + a large build.
  - CONTAGION (doc 04): 4/5 hooks FEASIBLE (dock event, block-undock, crew-death+event, markers); per-ship
    stat-mod PARTIAL. Nearly a separate mod; DEFER-to-last per blueprint.
  - FACTION DEFECTION, SECTOR TRANSFER: PARTIAL/INFEASIBLE hooks — design-rewrite needed (feasibility doc).
- **C. SMALL NONE GAPS (bounded):** U2 backend-selection OPTIONS MENU (substrate done #198; needs the UI) ·
  trader/crew conversation targeting (managers/captains work; extend the target resolver) · D-A persona
  faction display-name cosmetic · TTS = explicitly OUT (ADR-009).

- **P7-a `SPECIFIED` WAR FATIGUE → PEACE (re-home, builds on P6-a's Snap):** on a pulse transition INTO 'war',
  stamp `'$t_'+key = player.age` in Snap. Each tick, for pairs at war with age ≥ $WarFatigueHours (default 3h,
  tunable), STEP the relation upward via the PROVEN set_faction_relation actuator (+0.1/tick) with a
  "peace talks" diplomacy logbook line; the pulse's own transition detection then reports the peace naturally.
  GUARDS: never pairs involving player (their wars are theirs) or xenon/khaak (design-permanent hostiles);
  RECONCILE note: faction-loss-based fatigue deferred — the combat watch is player-fleet-scoped only
  (ai_influence_combat.xml $Watched), galaxy-wide kill groups would be heavy. Time-at-war is the honest
  deterministic v1 signal (doc 03 warfatigue-seek-peace + peace-sign). Acceptance: a forced war pair
  de-escalates over ticks with logbook trail; unchanged pairs untouched; player/xenon pairs never touched.

- **P6-a `SPECIFIED→in-progress` GALAXY PULSE (re-home, ADR-009): deterministic war/peace event detection in MD.**
  Bridge OFF by default now (cutover flip 2026-07-21 after Ken disabled the extension) — the news/events lane
  re-homes as: `Galaxy_pulse` cue in ai_influence_galaxynews.xml, 5-min loop (Poll_tick pattern), iterates
  unordered faction pairs (do_all counter pattern, $j gt $i) over the worldsync id list, buckets
  relations (same thresholds as U1: war<-0.5<hostile<-0.125<neutral<0.125<friendly<0.5<allied), compares vs a
  SAVE-PERSISTED `$Snap` table on the namespaced cue (Registry '$'+key pattern), and on a bucket TRANSITION
  writes the logbook (→war = alerts + notification; war→ = diplomacy 'peace'; else diplomacy line) + stores
  the new bucket. First run seeds silently. ZERO LLM, zero bridge, all state in-save.
  **Acceptance:** Forge validate 0 errors; in-game: first tick logs `pulse seeded N pairs` (debug), second tick
  logs `pulse clean` with NO logbook spam on an unchanged galaxy (negative path); ◐ a real transition line on
  the next natural/forced relation shift. Machine evidence = debug lines; player evidence = logbook entry.

## 🔥 SERVERLESS REBUILD PROGRAM — next units (ADR-006/ADR-007; Ken 2026-07-21: keep going until the mod
## satisfies C:\Users\Moshi\Desktop\X4 AI Influence\AI Influence - Systems)

## FINDINGS from driving a REAL conversation 2026-07-21 (U1 grounding PROVEN on screen; two defects):
- **U1 (P3-a) grounding PROVEN in a live wheel conversation:** typed "My name is Commander Vega. What sector
  are we docked in?" → NPC replied "Commander Vega, we're currently docked at Hewa's Twin I." = the REAL sector
  (MD read → prompt → LLM used it). Name recognized; memory accumulates (2nd turn logged turns=2 msgs=4 with the
  Vega history carried); identity token stuck via blackboard across turns. This flips ROADMAP #193 exp◐ and #194
  identity◐ on MY screen for the intra-session case (cross-reload recall still = Ken/EG-1).
- **DEFECT D-A — STANDING FIXED (grounded) 2026-07-21; two ◐ tails remain:** the standing half is DONE.
  Root-caused by an in-game property probe ([REPRODUCED], not guessed): for a station manager NPC,
  `event.object.owner` = the STATION (not faction) and `event.object.owner.owner` = NIL, so the naive
  `.owner.owner` chain was wrong. Proven accessor: `event.object.owner.relationto.{faction.player}` (vanilla's
  11-use pattern; probe returned 1 for the player-owned test station). FIX: compute the standing bucket in the
  conversation setup (Add_speak_choice, where event.object is in scope) into State.$standing; Open_chat now
  reads `if State.$standing? then … else 'neutral'` (guarded = regression-safe) instead of the broken
  `faction.{$faction}` string read. Forge-validated ok:true. ◐ TAILS: (1) on-screen standing-reflected-in-reply
  needs a NON-player-owned NPC (the test manager is player-owned → always 'allied', can't show buckets);
  (2) COSMETIC — the token/persona `faction` slot still carries the station display name and role still defaults
  'crew' (event.object.role was null for the manager); harmless for card keying, mildly wrong in the persona
  line. Low priority; get the faction display name + real role in a later polish pass.
- **DEFECT D-B `spec'd` — direct chat is SLOW (~10-13s) while the bridge runs:** the direct :4315 lane and the
  bridge sync flood (relations/sectors/index every 15s + economy/fleets/census) share ONE djfhe client;
  bridge traffic starves the chat request (bridge-stopped it was ~1.5s). Resolves for free at the serverless
  end state (bridge removed), but until then: throttle the bridge sync cadence during an open conversation, or
  give the chat lane priority. Track; do not fix before the sync lanes migrate off :8713 (later phases).
## ✅ P1 NO-PYTHON VERTICAL SLICE SHIPPED → ROADMAP #193 (2026-07-21). THE STOP/GO GATE IS OPEN:
## NPC recalled the taught phrase across save+reload WITH THE BRIDGE KILLED and :8713 closed. ◐ tails:
## (a) EXPERIENCE — Ken holds a wheel conversation and sees direct-lane replies on screen; (b) the dead
## Hotkey_API registrations (Shift+C chat opener included) need a root-cause or replacement — pre-existing.
## ✅ P2 MEMORY & IDENTITY SHIPPED → ROADMAP #194 (2026-07-21). Selftest 10/10 live. ◐ tails: blackboard
## identity stickiness across reload (rides next real conversation); replies don't yet write facts (Phase 4).
## Next mod units are chosen by wiki/x4-neural-link/spec-coverage-map.md (systems-doc reconcile, 2026-07-21).

- **P2 (SHIPPED — historical spec) MEMORY & IDENTITY.** Lane FULL. All schema logic
  lives in LUA (MD stays a dumb string store — cards are opaque JSON to Cards.$store).
  **Scope:** (a) card schema v2: `v` + checksum (djb2 over payload; verify on load, quarantine+fresh on
  mismatch — closes the param3/truncation corruption hazard); (b) migration: P1 cards (no v) migrate to v2
  losslessly, unknown future v = quarantine not crash; (c) Stardew-derived caps + weighted compaction:
  turns≤8 (have), facts≤200 evicted by weight desc then day, important≤64 with AUTO-PROMOTE for categories
  promise/secret/preference/relationship, card byte-cap ~6KB with lowest-weight eviction; (d) deterministic
  fact API `AddCardFact(token, text, provenance, weight, category)` with dedup — provenance enum
  game_observed|player_claim|npc_claim|model_color (ADR: only game_observed may later authorize gameplay);
  (e) identity: `resolveNpcToken` — blackboard-sticky per-entity token when an NPC entity is in scope
  (read $aic_identity, else mint name|faction|role#suffix + SetNPCBlackboard), legacy name|faction|role as
  fallback + aliases[] merge; same-name collisions get distinct suffixed tokens. (f) SAVE ISOLATION: FREE by
  construction on this substrate (the store travels INSIDE each save file) — documented, no code.
  **Out of scope:** LLM fact extraction (Phase 4 wires the structured reply's memory_updates), embeddings,
  cross-save Player2 Game Data mirroring (PUT still 500s).
  **Validation:** Forge validate green; gated on-load probe suite (P2_PROBES flag): encode/decode+tamper
  detection, caps+auto-promote+weighted eviction, migration from a P1-shape card, token-mint uniqueness;
  in-game F9 cycle proving probes PASS in the live runtime; blackboard stickiness across reload = ◐ rides
  the next real conversation open (existing BlackboardProbe infra). Evidence → ROADMAP close.
- **P1-polish `spec'd`:** suggestions/openers piggyback on the SendDirectChat reply (BUD-1, kills the
  per-wheel /api/suggest call); joules preflight (BUD-4); per-lane in-flight latch (BUD-2 slice).
- **LLM-BUDGET `spec'd` (Ken 2026-07-21, "later" priority): cut calls/hour toward the Bannerlord bar.**
  Evidence: our mod logged 334 completion calls in ~1h (Player2 joules ledger, gpt-oss-120b, 345,987 tokens)
  vs Bannerlord ~67/h. **Reference-mod deconstruction DONE (wiki reference-mod-deconstruction-2026-07-21;
  Stardew decompiled C# + Bannerlord TECHNICAL_GUIDE).** Ranked techniques (measure first via capture proxy
  :4316, then cut):
  - BUD-1 KILL the per-wheel `/api/suggest` call — piggyback openers on the chat reply envelope
    (conversation.xml:84 raises AIChat.suggest on every Speak_menu open; aic_uix.lua:262 GETs /api/suggest
    uncapped → 5-10 completions/convo just for openers). BIGGEST single driver. Interim: cache last batch,
    re-request only when turn-count advanced.
  - BUD-2 autonomous cadence caps re-authored in Lua (daemon used to own them): per-faction-pair cooldown,
    per-faction daily decision cap, random inter-decision spacing, one-in-flight-per-lane latch. (Stardew:
    3/day, 8min/pair-2day cooldowns, 120-480s spacing, Interlocked in-flight guard.)
  - BUD-3 proximity/relevance gate: spend completions only on factions in the player's sector OR at war
    with the player. (Census already sector-scoped worldsync.xml:65; extend to GENERATION.)
  - BUD-4 joules preflight → DEFER to canned tier when balance < threshold (:4315 /joules; constitution-safe
    deterministic fallback, not math-fallback).
  - BUD-5 drop RoleRAG embeddings for keyword-postings + tag-overlap+recency scoring computed in Lua
    (Stardew has NO embedding API; removes an entire call class, survives serverless).
  - BUD-6 intent_id + processed-set idempotency on the action drain (closes a real double-apply-on-reload gap).
  Open Q (needs de4dot + runtime dump of the obfuscated Bannerlord DLL): does Bannerlord BATCH N faction
  diplomacy decisions into ONE completion? Highest-leverage unknown for the autonomous lane — defer unless
  BUD-1..3 don't close the gap.
- `spec'd` (#192): `$st.manager` dead MD reads in ai_influence_worldsync.xml:41-42 — remove or replace with
  the proven Lua tradenpc census surface (3 static warnings, zero runtime cost today).
- `spec'd` (#192): Player2 Game Data PUT returns HTTP 500 with the registered client ID (GET=404 key-not-found
  proves the ID is recognized). Investigate login flow (/login/web/{game_client_id}) or DRAFT-status gating
  before Phase 2 counts on Game Data as an optional card store.
> Closing an item = delete it here + write the dated, validation-cited entry in ROADMAP.md (Ken commits via
> Antigravity — agents never run git).
> History NEVER lives in this file. Verified history: ROADMAP.md. Decisions: F:\StarForge\wiki\x4-neural-link\decisions.md.
> ⚠ AGENTS: never read-modify-write this (or any) file through the SANDBOX MOUNT — stale reads truncate content
> (bit us twice 2026-07-01). Use the host file tools (Read/Edit/Write).

## ✅ HZ-2 SHIPPED → ROADMAP #182 (2026-07-05). `_gated_completion` is the sole completion POST (count==1,
## host-verified); wrapper/meter replica 6/6 + llm_gate_coverage_selftest 5/5 (RED if a new site appears). ◐ tail:
## one live chat turn to confirm the refactored complete()/npc_complete() end-to-end when the bridge is up.
## Minor follow-on (optional): npc_complete now builds full context before the gate, so a budget-exhausted turn
## pays the context cost — add a cheap non-debiting pre-check for early-exit only if profiling shows it matters.

## ◐ HZ-1 FIX SHIPPED → ROADMAP #181 (2026-07-05). Meter now a true ceiling: suggestions + per-turn summary +
## RoleRAG classifier all debit `_llm_gate` (llm_meter_selftest 6/6). REMAINING (◐, needs server up): one LIVE
## spend-count confirming a real chat turn debits 3, and that graceful-degradation-under-limit doesn't harm the
## in-game experience. Re-open here only if the live count disagrees with the replica.

## 🗺️ SYSTEMS ROADMAP — gap-analysis 2026-07-05 (full matrix: wiki/x4-neural-link/gap-analysis-systems.md)
Tier order by LEVERAGE (finish strong core → events → diplomacy consequences → actions → character → orthogonal
new subsystems LAST). Each is scoped to EXTEND existing infra (reconciled), not rebuild. Validate every unit with
Forge/selftest + live bridge + in-game (ADR-G3).

TIER 1 — FINISH THE CONVERSATIONAL CORE (highest leverage; mostly extend):
- SYS-1 ✅ 2026-07-05 → ROADMAP #185 (salient_event_for_npc + "ON YOUR MIND" nudge in build_situation_briefing;
  live 6/6). ◐ experience gate: Ken sees an NPC raise a live event unprompted in-game.
- SYS-2 ✅ 2026-07-05 → ROADMAP #187 (_maybe_event_hail reuses player_comms + salient_event_for_npc; live 5/5).
  ◐ experience gate: Ken sees an unsolicited faction hail on the comms panel in-game.
- SYS-3 `spec'd` Trading-through-dialogue (01): NPC offers/barters wares + station modules in chat, priced by
  relationship/persona. NEW — ground vs vanilla trade offer. Validate: a chat deal moves credits/ware in-game.
- (M2 in-game VOICING confirm = Ken's eyeball; tracked in the M-chain task.)

TIER 2 — LIGHT UP EVENTS (force-multiplies dialogue + diplomacy):
- SYS-4 `spec'd` AI EVENT GENERATOR (02): DETERMINISTIC (prose≠state) — `generate_world_events(save)` follows the
  agreement_candidates pattern: derive multi-category world_events from REAL state — POLITICAL (high mutual
  resentment, not at war), ECONOMIC (severe shortage), SOCIAL (war-weariness in a long/intense war). Deduped by
  `gen:<cat>:<key>` source, capped, on the maintenance tick; then the existing gossip spread (#175) carries them
  and SYS-1 surfaces them. NO LLM for the STATE (the narrator adds flavor on top). Validate: generated events
  across categories + dedup on re-run + exclusions.
- SYS-4 ✅ 2026-07-05 → ROADMAP #190 (generate_world_events, deterministic 3-category, deduped, on maintenance
  tick; live 7/7 + dtick 8/8). Completes the generate→spread→surface→hail chain.
- SYS-5 `spec'd` Event EVOLUTION (02/10): events update/RESOLVE over the maintenance cadence (vs fire-once) —
  e.g. a generated `gen:*` event whose triggering condition has cleared gets a resolution follow-up event +
  retired; economic ripple. Extend the maintenance tier beside generate_world_events.

TIER 3 — DIPLOMACY CONSEQUENCE LAYER (negotiation exists; execution doesn't):
- SYS-6 `spec'd` Diplomacy ROUNDS (03; = blueprint P, spec'd #154): turn-taking faction moves with realistic
  delays so politics unfold believably. Ride the strategic tick.
- SYS-7 Consequence EXECUTION (wire negotiated agreement TYPES to REAL effects):
  - SYS-7a ✅ 2026-07-05 → ROADMAP #186 (alliance-shatter-on-war; live 6/6). Note: in-force agreement status
    is "accepted", NOT "active" — filter accordingly.
  - SYS-7b ✅ 2026-07-05 → ROADMAP #188 (settle_tributes: balanced record_budget_spend/income, affordability-
    gated, on the maintenance tick; live 7/7 + dtick 8/8). TREASURY MODEL banked below.
  - SYS-7c ✅ 2026-07-05 → ROADMAP #189 (_settle_reparations on war-end; marked settled; live 8/8).
  - SYS-7d ✅ 2026-07-05 → ROADMAP #189 (_transfer_sectors_on_peace; sector_transfers term; live 8/8).
  SYS-7 (diplomacy consequence layer) COMPLETE — 7a/7b/7c/7d all live. Diplomacy thread remainder: SYS-8 defection.
  TREASURY MODEL (reconcile #188): faction treasury is DERIVED (budget_capacity = owned stations × 250k × health);
  the mutable part is `faction_budget.spent`. Move money with record_budget_spend (debit) + record_budget_income
  (credit, spent may go negative = surplus). Affordability gate = validate_earned_transfer. In-force status="accepted".
- SYS-8 `spec'd` Defection/splinter (03): a minor faction breaks from its parent + reintegration path.

TIER 4 — HARDEN ACTIONS (09; mostly done):
- SYS-9 `spec'd` Round out subordinate order set on the OPORD pipeline: attack-target, blockade/assault, raid,
  create-fleet, return-to-player as DIALOGUE-issued orders. Validate: each dispatched via chat, seen in-game.

TIER 5 — CHARACTER DEPTH (build on the memory substrate):
- SYS-10 `spec'd` Loyalty & Bond (06): bond levels unlocking dialogue, NPC initiative-to-bond, formal-commitment,
  culture-colored progression, decay — on the existing affection/loyalty/attraction columns.
- SYS-11 `spec'd` Death History (08): narrator-driven life-story on hero death, gated at 50+ interactions (turn
  counts already exist), polished display, opt-out. Reuses the narrator.

TIER 6 — ORTHOGONAL NEW SUBSYSTEMS (LAST; large, in-game-heavy, share no core substrate):
- SYS-12 `spec'd` Station Combat (07) — DEFER until the conversational core is polished + demoable.
- SYS-13 `spec'd` Contagion (04) — DEFER to last; a self-contained survival subsystem, nearly a separate mod.

## ⚠ READ FIRST — quickload does NOT reload ui/*.lua. THE FAST PATH (Ken): in-game chat commands
## **/reloadui** (reloads Lua) and **/refreshmd** (reloads MD) — no restart, no F5/F9 needed. Confirm the
## resident Lua via the "LUAV=3" marker in the poll log before trusting offer/accept behavior.

✅ BRIDGE RESTORED + A4 slice-2 VERIFIED 2026-07-02 14:21 → ROADMAP #123 (CI GATE PASS ×2; route 7/7 incl.
player2_verb_choice_rides_job; full regression sweep green). Watcher tool-improvement (RED line should carry
the failing check name / first trace line, not just "unreachable") logged below under Tooling.

## NEXT SESSION — first 20 minutes (UPDATED 4th: post-#94, 2026-07-02 marathon end)
-1. READ ROADMAP #84–#94 (the whole contract lifecycle shipped + in-game-proven this run: accept/claim,
    abort+rep, FRAGO push, patrol RML, escort binding, guidance fix, urgency window). Debuglog is directly
    grepable via the connected save folder. Direct evidence beats the log-tail window.
0a. IN-GAME GATES with Ken (= G6 core): patrol contract flown to COMPLETION → yellow RML objectives →
    reward_player credits + rep + "Contract fulfilled" + bridge /v1/job/complete (budget_spent). Escort
    contract: guidance to the REAL freighter → 15km proximity → convoy runs to AO → paid (or ship dies →
    hostile_event on dashboard). FRAGO on a claimed contract: description update + notification.
0b. Then implement the three remaining RML handoffs — params ALREADY GROUNDED (see G4 item below): supply →
    DeliverWares (research gm_supplyfactory Offers construction FIRST), bounty → Destroy_Entities (real
    hostiles group), recon → Scan (TargetStation mode).
0b. ~~ACCEPT LISTENER~~ ✅ 2026-07-01 → ROADMAP #84 (kuertee actor-signal shape; ACCEPTED line + mission in
    manager + bridge claimed — G3 CLOSED after 6 attempts).
0c. ~~ABORT slice~~ ✅ IN-GAME 2026-07-02 → ROADMAP #88 addendum (Ken's live abort: ABORTED line + mission
    cleared + trust −2 / rep −0.02 both layers + job re-listed).
0f. `in-progress` G4 IN-GAME GATE, live with Ken: accept/activate/abort/penalty/escalation-raise ALL PROVEN
    (#88 addendum). OPEN: no yellow objective line on our mission entry — awaiting Ken's mission-popup
    screenshot to discriminate empty-objectives vs undock-first (rml_patrol.xml:301, he was docked) vs working.
    Then: fly the patrol → complete → PAID = G6 core.
0d. ~~STRIP [AI TEST] force-war slice~~ ✅ 2026-07-02 → ROADMAP #85 (also found: it re-forced war on EVERY load
    via md.Setup.Start). OPEN residue: live save still carries the forced -1.0 alliance→player relation — ask Ken
    whether to restore to 0.
0e. ~~ABORT costs reputation~~ ◐ 2026-07-02 → ROADMAP #85 (MD -0.02 + logbook; bridge trust -2 player-only,
    unit-tested). In-game verify rides the 0c abort pass (/refreshmd + /reloadui → accept → abort).

## PREVIOUS (superseded) first-20 list
0. G3 accept fix attempt 3: TOP-LEVEL bare `<event_offer_accepted />` + `event.cue.$job` matching (see ROADMAP
   #75-G3 addendum 2 — child-of-instance listeners don't receive the event, two shapes proven dead). Also one
   debug_text on $d.$task? to pin the Objectives-dup (bridge side ruled out). Then accept → claimed proof.

## PREVIOUS first-20 list
1. F5/F9 reload → fresh offers carry the doctrinal SMESC briefing + element-task objectives + correct 70k rewards
   (ROADMAP #77/#78 ◐) — screenshot a briefing, flip #77/#78 ✅.
2. G3 accept→claim fix (ShowOffer listener pattern, ROADMAP #75-G3) — then accept a contract and verify
   /api/jobs status=claimed.
3. G5 load-time cleanup: cancel stale savegame offer instances (700 Cr / 7M Cr rows).

## Keystone (player-facing)
- **N — NPC CONTRACTOR EXECUTION (spec'd 2026-07-02, Ken: "why are the NPCs not taking these missions? ...the
  NPCs should actually execute the mission, not just pretend").** The market was DESIGNED claimant-agnostic
  (claim_job takes any claimant; memory.py:4371 "NPC/faction claimants... read the full table via their own
  decision drivers") but no NPC decision driver or execution exists — jobs sit until the player takes them or
  escalation/battle-resolution clears them. Constitution: execution must be REAL, never prose. Slices:
  - ~~N1 CLAIM DRIVER~~ ✅ 2026-07-02 → ROADMAP #128 (contractor_claims_selftest 8/8; DARK until N2 —
    manual /api/ops/contractor_claims only, never the heartbeat, per constitution).
  - N2 ◐ BRIDGE-VERIFIED 2026-07-02 → ROADMAP #131 (contractor_claims_selftest 11/11; rides the proven OPORD
    actuation pipeline, zero new game-side code). IN-GAME PENDING: one manual /api/ops/contractor_claims on
    the live save → SEE a claimant-faction ship leased+ordered (debuglog + dashboard lease + ship moves) →
    Ken sets `contractor_claims_enabled: true` in config → flip ✅.
  - ~~N3 COMPLETION→PAYMENT~~ ✅ 2026-07-02 → ROADMAP #133 (contractor_claims_selftest 15/15; the N chain is
    bridge-complete: claim → execute → settle, awaiting the in-game dispatch gate).
  - ~~N4 BOARD VISIBILITY~~ ◐ 2026-07-02 → ROADMAP #138 (contractor 17/17 + narrator 11/11; in-game article
    sighting rides Ken's #131 dispatch check — the SAME trigger flips both).
  - N4b ◐ 2026-07-02 → ROADMAP #145 (dashboard Contractor Operations panel + contractor_underway hull-named
    narrator event ✅, 21/21 + browser-confirmed). REMAINING (Ken-experience half): IN-GAME logbook +
    notification on contractor dispatch naming ship + sector — MD authoring (Withdraw/Offer file or
    aic_main), rides the next MD unit + /refreshmd.
  - N2 REAL EXECUTION (MD/aiscript): a claimed-by-NPC job tasks a REAL ship of the claimant faction —
    find_ship + create_order per the DeadAir pattern (x4-reference-mods: create_order recipes), the same verb
    gates as the player path (RML equivalents via aiscript orders). The ship visibly flies the mission.
  - N3 COMPLETION SENSING: same observed-evidence bar as the player path (kill events / arrival / window
    survival → hostile_events/logbook) → complete_job(claimant=faction) → reward moves ISSUER treasury →
    CLAIMANT treasury (the economy loop Ken's force-economics doctrine needs). Failure/ship-loss → job reopens
    + hostile_event.
  - N4 PLAYER-VISIBLE: board shows "claimed by <faction>" (offer withdrawn, logbook/news line); the player can
    watch the contractor work. IN-GAME GATE applies to every slice.
  Dependencies: rides W's galaxy topology for reachability; N1 is buildable now (bridge-only).
- **R — MISSION CAPABILITY REQUIREMENTS (THE SUBSTANTIATION SET — Ken 2026-07-02): wiki
  [[opord-mission-requirements]] is the authoritative scoreboard.** R1-R11 Tier-1 missions must each be flyable
  AND payable in-game (the #97 standard) for the OPORD gameplay to count as delivered. R1 escort ✅ paid ·
  R3 patrol ◐ · R2/R4-R11 spec'd. A4 (verb engine) is the shared substrate; each R-row is then a thin slice.
  Flip rows only with cited in-game evidence.
- **A — ASSESSMENT LINKAGE (parent; Ken doctrine 2026-07-02: "these things need to be linked to the cause")**
  Every mission must trace to the ASSESSED event that spooled it; the NATO sequence's assessment phase is the
  source of record, not accept-time improvisation.
  - ~~A1~~ ✅ 2026-07-02 → ROADMAP #99 (floor OP_MIN_EVENTS=2/OP_MIN_MAGNITUDE=6 + assessment record with
    threatened_assets in op evidence; recognize_selftest 12/12 live). A2 now has its binding pool.
  - A2 `◐ GENERALIZED 2026-07-02` → ROADMAP #101 + #113 (verb-aware bind: escort→surviving ship,
    defend→damaged station; every gate reads the assessment first; destroy sector-scoped = honest limit).
    IN-GAME proof pending: "CAUSE-LINKED bind" debuglog lines on the next combat-op escort/defend contracts. (Ken doctrine 2026-07-02: "the escort target needs a
    goal... 'you will escort your target to safety', not 'in circles for 20 minutes'"): at op formation record
    "assets under threat" (victim ships/routes from the triggering hostile events) into op evidence; accept-time
    binding draws from that list (alive → bind), fallback = victim-faction freighter transiting the AO/route;
    NO cause-linked candidate → do NOT post an escort (rule: bindable CAUSE-LINKED object). THE GOAL IS PART OF
    THE ORDER: destination derives from the op (the threatened route's endpoint), and it is STATED consistently
    in the SMESC mission statement, the briefing, the objective text ("Escort <ship> to <station>"), and enacted
    by the ship's behavior (#96's dock-destination is the mechanical half). Also: commandeer on a squadron
    leader moves ALL 4 ships — decide whether convoy=squadron is a feature (bigger convoys) or bind loose hulls
    only. Replaces #93's nearest-hull-anywhere.
  - A3 `◐ core live 2026-07-02` → ROADMAP #102 (probation tier: trust ≤ -10 hides >100k contracts; selftest
    10/10 incl. recovery). REMAINDER: in-game rep weighting via relations_sync · preferred-tier perks
    (advances/exclusives) · deposit mechanics.
  - `spec'd→◐` PATROL WINDOW FROM ASSESSMENT → ROADMAP #102 (mintime 3min×urgency; rides next /refreshmd).
  - A6 `◐ CORE LIVE 2026-07-02` → ROADMAP #104 (pricing ceiling) + **#108 (decision half: costed options in the
    routing brief, accept_risk route, economy convoys through the chooser — route_decision_selftest 6/6)**.
    ~~risk consequence watch~~ ✅ #109 (sweep_risk_watches 4/4 — realized gambles attributed to the op ledger).
    ~~seek_ceasefire~~ ✅ 2026-07-02 → ROADMAP #124 (broke+war-eligible → political option; route_decision
    12/12; in-game observation of a live broke faction choosing politics = ◐ rides the decision cadence).
    ~~threat-scaled treasury fraction~~ ✅ 2026-07-02 → ROADMAP #126 (pricing 11/11).
    REMAINDER: in-game observation of a real accept_risk convoy loss feeding back (cadence-gated ◐). ORIGINAL SPEC — FORCE-ECONOMICS GATE — make-vs-buy-vs-TALK (Ken doctrine 2026-07-02: "they should be using
    politics to avoid war while they build their economy, not giving all their money to contractors... they
    literally have hundreds of ships"): BEFORE commissioning a contract, Player2's decision must weigh the
    LEGAL OPTIONS with real costs attached: (a) TASK OWN FLEET — fleet_strength shows availability (antigone:
    283 fight ships); cost = opportunity/attrition risk, not treasury; (b) HIRE CONTRACTOR — treasury cost,
    capped as % of available (a 2.1M faction posting 232k patrols = 11% of liquidity on ONE contract is
    irrational); (c) DIPLOMACY — the negotiation system already exists (allied_support, agreements): broke or
    losing factions should sue for de-escalation/support, not outspend; (d) ACCEPT RISK (do nothing, log the
    assessment). Contracts become what they are in reality: the option for surge capacity and jobs OWN forces
    can't cover — not the reflex. Engine derives the option set + costs deterministically; Player2 chooses
    (ADR-001). Also: contract pricing ceiling as fraction of available treasury, scaled by fleet-coverage gap.
  - `spec'd` PATROL WINDOW FROM ASSESSMENT (with A6): mintime/maxtime in the patrol Destinations entry derive
    from op urgency/magnitude (10-30min, not the hardcoded 1min/10min that paid 232k for 60 quiet seconds);
    quiet-AO completion pays partial (presence) vs full (contact handled) — completion QUALITY in evidence.
  - ~~A5~~ 🏁 COMPLETE 5/5 2026-07-02 → #106 (d) · #110 (a)(c) · #120 (e) · #121 (b: engagement_id +
    co_victims in assessments; recognize 17/17). Follow-ons banked: per-engagement contract caps ·
    follow_support toward co-victims · galaxy topology sync (nearest-safe, route-aware interdiction — W-adjacent).
  - A4 `◐ slice 1 live 2026-07-02` → ROADMAP #105 (TASK_VERBS table + derive_legal_verbs from assessment +
    task_verb/legal_verbs on every op-minted job; verb_engine_selftest 7/7). SLICE 2: Player2 in-set choice at
    routing · verb-conjugated SMESC templates · MD gates by task_verb · economy types through the EXISTING
    route_task chooser (reconcile: make-vs-buy-vs-talk already exists for combat — extend, don't rebuild).
    ORIGINAL SPEC — MISSION TASK VERBS = the contract type system (Ken doc 2026-07-02; wiki [[mission-task-verbs]],
    raw source in StarForge raw/): verb DERIVED from assessed cause + target ACTIVITY; each verb has binding
    PRECONDITIONS (escort requires an entity ON THE MOVE with a destination — #97's patrol squadron made escort
    ILLEGAL; correct verb was Follow and Support), an RML mapping, and doctrinal SUCCESS criteria; Player2 picks
    from the LEGAL verb set (ADR-001). Mission statement, objective, binding, gameplay, and completion evidence
    must all conjugate the SAME verb. Implement one verb slice at a time — Follow and Support first (#97 proved
    the demand); verb table lives as bridge data.
- **W — WAR INDUSTRY pipeline** (parent; Ken directive 2026-07-01; spec: wiki [[war-industry-pipeline-spec]]) —
  losses → Player2 build decision → build_orders at REAL shipyards → ware bills → market supply jobs → observed
  deliveries → real hulls → fleet_strength → OPORD force. Order: W2 RESEARCH (build-placement recipe, BLOCKS all)
  → W1 ledger → W3 market wiring → W4 completion → W5 dashboard panel.
  - W2 research note ✅ (in spec, 2026-07-01): no MD API for literal shipyard queues — v1 placement = DeadAir
    JOB-QUOTA raise; hull completion = OBSERVED fleet-count delta.
  - ~~W1~~ ✅ 2026-07-02 → ROADMAP #140 (build_orders_selftest 6/6; DARK until W2 placement — manual
    /api/ops/build_decisions only).
  - ~~W2 IMPLEMENTATION~~ ◐ 2026-07-02 → ROADMAP #148 (build 10/10, Forge structural 0; IN-GAME PENDING:
    jobs.xml loads at GAME LAUNCH — Ken's next full X4 restart arms it; then a manual
    /api/ops/build_decisions on the live save should produce the `AIC W2 build_place ... found=N` debuglog
    line = execution gate).
  - ~~W3~~ ✅ 2026-07-02 → ROADMAP #151 (build 12/12; supply demand from real yard needs, dual-surface).
  - ~~W4 + W5~~ ✅ 2026-07-02 → ROADMAP #153 (build 17/17 · coverage 28/28 auto-verified hull_launched ·
    panel browser-confirmed). **W1-W5 ALL BUILT.** Remaining W items: `war_industry_enabled` cadence flip
    after the first LIVE placement is observed (organic force demand) · supply demand scaled by order size
    (#151 pick) · galaxy topology (W-adjacent).
- **⭐ UNIFIED DESIGN SPEC (2026-07-04, ROADMAP #157): `F:\StarForge\wiki\x4-neural-link\
  unified-design-spec.md` is now the CANON consolidation of the five design docs — build-order table
  §11 (N-1…J-1). New work in the N/E/P/S/G/M/J lanes cites ITS sections; keystone B's D/T/P/S chains
  remain the player-experience umbrella (C chain = §6's presentation layer; P chain = §7's autonomous
  lane; T chain = §6/P-3).** First buildable unit: **N-1** (agreements schema extension + event history
  + expiry sweep).
- **I — INTRIGUE: rumors, espionage, false flags (Ken 2026-07-05: "these things are important, even if
  they are lies"). CONSTITUTIONAL KEY: prose ≠ truth, but BELIEF IS STATE — a lie creates a CLAIM record
  consumed by existing machinery (emotions, assessments, deciders); validators/relations never touched
  directly. Lying works, lying costs, exposure brands you.**
  - **I0 `spec'd` THE SEED/ASK DISTINCTION (Ken 2026-07-05 + #163's empirical proof — THE key design):**
    ASK = demands a decision now → routes to persuade/decide → proof demanded (#163: Split refused
    fabricated intel). SEED = a rumor TOLD, nothing asked → claim recorded, credibility-scored,
    absorbed into memory + bounded emotion deltas + world_event(kind=rumor) — NO decision, NO proof
    gate. Seeds accumulate; the EXISTING autonomous loop (L3 grudges → review_faction pressures → war
    phases) then produces the war ON ITS OWN. Bannerlord parity achieved the honest way: their rumors
    skip verification entirely; ours adds credibility + exposure so lying is a GAME, not a cheat.
    Chat intent split: accusation-with-ask → persuade lane; report/story-without-ask → rumor lane.
  - I0b `spec'd` VERIFIABILITY + OUTRAGE CLASSES (from Ken's "comms-blocked region" example):
    every claim carries verifiability — UNVERIFIABLE (dead zones, no witnesses): believed weaker,
    decays slower, near exposure-proof · VERIFIABLE: hits harder, checked fast vs the truth ledger,
    high exposure stakes. Outrage classes (atrocity > sabotage > fleet movement > trade slight):
    multiplier on resentment/fear deltas AND on the exposure penalty when disproven — the atrocity lie
    is the strongest poison and the career-ender when caught.
  - I1 `spec'd` CLAIM STORE: claims(save, claimant, told_to, accused, alleged_event_type, sector, ts,
    credibility, status: unverified/believed/disproven/expired, evidence_refs). Player chat asks route
    here (extends the D3 intent seam: accusation intents).
  - I2 `spec'd` CREDIBILITY ENGINE (deterministic, #155 pattern): claimant trust + plausibility vs the
    REAL hostile_events/relations ledger (accused active nearby? any matching unattributed incident?) +
    tone + prior-lie history. Below floor = disbelieved to your face.
  - I3 `spec'd` BELIEF CONSUMPTION: believed claims emit BOUNDED emotion deltas (L3 grudge system) and
    enter assessments as LOW-CONFIDENCE evidence (weight scaled by credibility) — tilting patrols,
    contracts, war pressure through the standard pipeline. Never a direct relation write.
  - I4 `spec'd` VERIFICATION + EXPOSURE SWEEP: periodic check vs the truth ledger; unsupported claims
    decay/expire; DISPROVEN → trust crash + resentment + player_role 'deceiver' + narrator scandal
    (rumor-vs-confirmed distinction per spec §9). Repeat liars face credibility floors.
  - I5 `spec'd` WITNESS MODEL + FALSE FLAGS: attacks with no friendly sensor nearby record
    attacker=UNKNOWN in hostile_events; rumors SUPPLY attribution for unattributed incidents (the
    false-flag loop: manufacture incident → name your enemy → recognition pipeline reacts). NPC
    factions may later use the same lane (P-chain espionage).
  - **CANONICAL ACCEPTANCE SCENARIO (Ken 2026-07-05): player says "I bring intel that the Argon are
    sending fleets to destroy you."** → claim recorded (accused=argon, type=fleet_threat) → credibility
    vs TRUTH ledger (real fleet census deltas + Argon presence near listener's sectors + standing +
    player trust/lie history; nothing nearby = disbelieved IN CHARACTER off the console) → believed:
    fear/resentment up (bounded) + LOW-CONFIDENCE threat evidence into assessments → defensive
    force_requests (feeds WAR INDUSTRY — keels laid against a phantom) + border patrols → their REAL
    mobilization may trip Argon's own threat recognition = the spiral, emergent, no forced war →
    verification sweep: no fleets ever come → disproven → trust crash + 'deceiver' role + narrator
    scandal + credibility floor. TRUE intel confirmed instead → trust surge, informant career. Selftest
    covers both forks + the disbelief-at-the-door fork.
  - I6 `spec'd` GOSSIP PROPAGATION: claims spread via social-graph publicity + blueprint §13.5 delays
    (witnessed → same faction → allies → rumor), so a lie told on one station takes time to reach High
    Command — and mutates who believes what.
- **CFG — TICK CONTROL PANEL / mod config menu (Ken 2026-07-05: "every tick we do should be adjustable").**
  Reconcile 2026-07-05 found the tick inventory scattered across three layers — the spec unifies them.
  Two prerequisites, then the menu.
  - **THE TICK INVENTORY (grounded, 2026-07-05 — the set the panel must cover):**
    - *MD/Lua in-game cadences (aic_contracts.xml / aic_uix.lua):* master **Poll_tick** heartbeat (Do_sync
      ~15s — relations/OPORD/chat poll) · Registry_heal 10s · Orphan_check 60s · KeepAlive 1min ·
      Escort_Telemetry 60s · Escort_Begin 5s · Recover_Claimed 10s.
    - *Bridge governor (player2_client, runtime-tunable via /v1/llm/budget_set):* calls/min (6) · calls/hr
      (90) · chat_reserve (2) · color/hr (20) · **autonomous_min_interval_s (150, #172)** · session budget ·
      kill switch.
    - *Bridge strategic/event cadences (mostly HARDCODED constants — the real work of this keystone is
      promoting them to config-driven + runtime-tunable):* influence_step **factions-per-tick** (budget=2) ·
      **LLM_NEWS_BUDGET** (2/tick) · **REACTION_BUDGET** · **DECAY_INTERVAL_S** (emotion decay) ·
      event_flush_interval_s (12) · event_batch_size (25) · JOB_ORPHAN_TTL_S (3600) ·
      PERSUASION_FATIGUE_WINDOW_S (7200) · persuade cooldown (600s) + daily cap (5) · SELF_AUTHORED_TTL (1800)
      · hostile-event windows.
    - *Feature flags (already config, belong in the menu):* persuasion_enabled · contractor_claims_enabled ·
      war_industry_enabled · dice_checks_enabled · persuasion_min_interval.
  - ~~CFG-1~~ ✅ 2026-07-05 → ROADMAP #176 (RECONCILE: strategic tick was already decoupled via the
    daemon+tiered decision_tick; built the maintenance tier that DRIVES the I-chain sweeps on cadence +
    made tier intervals config-tunable `tier_interval_<tier>_s`. dtick 8/8). Original spec below for ref:
  - **CFG-1 (done) STRATEGIC-TICK DECOUPLE (prerequisite).** The strategic/LLM work rides the 15s
    heartbeat today; "adjust the strategic tick" is meaningless until it has its OWN clock. Move the
    autonomous strategic tick (influence_step: faction reviews, decisions, news, reactions) onto a
    dedicated slow cadence (default 2-3 min, round-robin 1-2 factions/tick → galaxy cycles ~20-40 min,
    matching X4's war/economy pace), with an EVENT-OVERRIDE tier (war declared / station destroyed /
    player-relevant threshold fires immediately through the spend gate). Heartbeat stays 15s for cheap
    deterministic drain/sync. See the priority hierarchy (unified spec §9).
  - ~~CFG-2 + CFG-4~~ ✅ 2026-07-05 → ROADMAP #177 (CONFIG_REGISTRY + generic config_list/config_set +
    GET /api/config + POST /v1/config/set, 6/6; CONFIG_PRESETS potato/normal/high/experimental +
    config_apply_preset, 7/7). Config BACKEND complete; only CFG-3 (in-game menu UI) remains. Orig spec:
  - **CFG-2 (done) UNIFIED CONFIG SURFACE (prerequisite).** Promote the hardcoded cadence constants to a
    single config store with a GENERIC runtime setter (generalize /v1/llm/budget_set → /v1/config/set over
    an allowlisted key set) + a GET /api/config that returns every adjustable tick with its value, default,
    unit, and safe min/max. One selftest asserts every panel key round-trips (set→get) and clamps to bounds.
  - **CFG-3 `spec'd` IN-GAME MENU (the deliverable).** A mod options menu — reuse the native gameoptions /
    SirNukes Mod Support API config surface if it fits, else our own UIX menu — grouped by category
    (LLM Spend · Strategic Cadence · Economy Sync · Memory/Decay · Contract Lifecycle · Feature Flags),
    each row a slider/toggle bound to a CFG-2 key, pushed to the bridge live (and MD Poll_tick interval via
    an MD var where the cadence is in-game). RESEARCH-first on the native config surface (like C2a).
  - **CFG-4 `spec'd` PRESETS.** The blueprint §19 performance profiles (Potato/Normal/High/Experimental)
    become named bundles over the CFG-2 keys — one click sets the whole tick profile. Bridges to S-chain
    (ship-it packaging). Per-session joule budget preset per profile.
- **WE — WORLD-EVENT ENRICHMENT (spec'd 2026-07-05 from Ken's World Event Update doc — a CONFIRMED live
  defect: world_events stores flattened prose w/ empty metadata; dashboard shows raw 110-char rows, not
  narrator articles). Extends unified-spec §9; R2 discipline (extend, never parallel). NEXT BUILDABLE
  after the C-deferral — this is bridge work, no UI dependency:**
  - WE-1 `spec'd` SCHEMA: extend world_events (title, cause, consequence, quote, related_job/agreement/
    conflict ids, evidence_json, status, expires_at, narrated_at) + new world_articles table (headline,
    body, consequence, quote, category, participants, cluster key, published flag).
  - WE-2 `spec'd` STRUCTURED EMITTERS: job market + negotiations + OPORD lifecycle transitions emit
    STRUCTURED events (participants/location/cause/links), never prose-first; backfill the empty-metadata
    writers found in the diagnosis.
  - WE-3 `spec'd` PRESENTATION SPLIT: dashboard World Events panel + logbook + NPC memory feeds read
    ARTICLES (narrator output), never raw rows; raw rows stay as the audit substrate. Dedup + aging.
  - WE-4 `spec'd` CRISIS LANE (from the Bannerlord Translation doc's disease→X4 conversion; optional,
    behind flag): X4-first crisis events — reactor leak, Xenon malware outbreak, workforce sickness,
    quarantine lockdown, medical-supply shortage — each a structured event + narrator arc + job/negotiation
    hooks through the standard transaction doors. New content, no new architecture.
- **B — BLUEPRINT COMPLETION (the final 25% — spec'd 2026-07-02 from the §27 gap audit, ROADMAP #154).**
  Source docs: X4_AI_Influence_Blueprint2.md §27 Definition of Done + the feasibility report. Audit verdict:
  strategic half ~90% built+proven; person-first social half ~35%. Four chains, in value order (Ken's
  benchmark first). Each chain follows the workflow; EXPERIENCE gates per ADR-G3.
  - **D — WAR-BY-CONVERSATION (persuasion → validated relation/war shift).** Ken's own bar: "I talked a lord
    into a war immediately" (Bannerlord proxy DB proof). RECONCILE: EXTENDS existing infra, near-zero new
    models — the chat pipeline (npc_complete), the negotiation door (submit_negotiation_intent + agreements),
    the ported dynamicwardiplomacy relation model, relations_sync, and the action whitelist. Never free-form.
    - ~~D1~~ ✅ bridge 2026-07-04 → ROADMAP #155 (persuasion_selftest 17/17 after C1 tones #156; refusals
      never reach the LLM; DARK behind `persuasion_enabled`; manual door /api/ops/persuade&tone=).
    - **⭐ D3-BRIDGE `spec'd — ACTIVE NEXT (Ken 2026-07-05: "persuading a faction into war… sounds more
      interesting than I gave it credit for"; NO UI dependency — pure bridge):** wire persuade() into the
      LIVE CHAT path. When the player's message to a FACTION-AUTHORITY persona (rep/High Command only —
      §6 authority model; a mechanic can't broker war) contains a relation ask, the chat handler routes
      it: (a) deterministic intent gate — detect ask + target + direction (declare war on X / make peace
      with X / stand down); grounded parse, no LLM classify call; (b) persuasion_willingness(tone from
      C1: the message's approach reads as charm/intimidate/bribe/neutral) → unwilling = the NPC's REPLY
      IS the in-character refusal (dialogue from the willingness reason — zero extra LLM cost); (c)
      willing → decide() agree/refuse/demand_proof; agree → validated banded move through the PROVEN
      actuation path; demand_proof → counter-creates a JOB (the "bring ships or bring proof" moment —
      §7.6 proof-task pattern). (d) D2 envelope in the same unit: per-(faction,target) cooldown + daily
      persuasion budget + the ±5/±25 bands already enforced. Selftest per branch; then KEN FLIPS
      `persuasion_enabled` and talks the Alliance toward war IN THE WHEEL — the experience gate that
      flips D ✅ and makes the Bannerlord benchmark real.
    - D2 `spec'd` HOSTILITY ENVELOPE: bounded relation delta with per-faction caps, cooldowns, daily budget,
      kill switch; DARK behind `persuasion_enabled` (default false). Scene-scale hostility first (a booster,
      not instant total war); full war declaration only at the envelope's proven edge.
    - D3 `spec'd` IN-GAME GATE (EXPERIENCE): Ken talks the Alliance rep toward war → relation visibly moves →
      logbook + notification + narrator article. Flips ✅ only on Ken's screen.
  - **C — CINEMATIC CONVERSATIONS (Mass Effect conversion — Ken 2026-07-04, FULL PUSH; source doc
    MassEffectConversationX4Conversion.md).** ME's grammar (tone wheel → gated branches → consequences →
    memory) + ME's cinema (staging, camera, voice). RECONCILE dividends: `suggest()` is ALREADY the ME wheel
    (named so in code, RAG-grounded openers); relationships carry FOUR axes (trust/fear/resentment/debt) vs
    ME's one — each tone plays a different axis; D1 persuade is the consequence engine; Player2 supplies TTS
    (the doc's High-effort voice gap is largely SOLVED for us); the bridge IS the conversation manager the doc
    wished for (its Lua-only assumption doesn't bind us — keep X4 thin per blueprint §6.1). Slices in order:
    - ~~C1~~ ✅ bridge 2026-07-04 → ROADMAP #156 (17/17 first pass; tone→axis + backfire priced on ledger;
      bribe CREDIT TRANSFER deliberately deferred to C2/C3 — needs UI confirmation per blueprint §10.5).
    - C1b `spec'd` D20 CHECK LAYER — **HYBRID (Ken confirmed 2026-07-04): dice ONLY on persuade-class
      stakes wedges; ordinary conversational wedges (the LLM-suggested contextual replies) NEVER roll.**
      (behind `dice_checks_enabled` for cockpit A/B): DC = (1 − willingness) × 20; modifiers FROM THE LEDGER with provenance (trust=charm mod,
      fear=intimidate mod, debt=bribe leverage, resentment=flat penalty). CONSTITUTION GUARDS: below a
      willingness floor the check is LOCKED (shown impossible, not rollable — no nat-20 past the engine's
      gates; band/eligibility never rollable); roll SEEDED from (save_id, conversation, ask) so quickload
      never rerolls (DE pattern — retry means CHANGE THE SITUATION). Outcome tiers: crit = full step +
      trust bonus · success = step · fail = refusal · crit-fail = backfire. Wheel wedges show live odds
      (BG3 legibility). Dice decide degree, model performs, engine validates (ADR-001 intact).
    - **C2 `spec'd` FULL-WHEEL CONVERSATION LOOP — THE CENTERPIECE (Ken re-scope 2026-07-04, screenshots on
      record: our current comm-link is a SQUARE BOX with stacked rectangular buttons; the target is ME's
      RADIAL — and Ken notes NATIVE X4 already ships a radial wheel).** HARD REQUIREMENT: the presentation
      is a RADIAL WHEEL — options arrayed around a hub, NPC line above or at center, no square conversation
      window, no button stack. Every turn: NPC line → 3-6 tone-tagged wedges (suggest() per-turn, grounded
      in running conversation + willingness) → pick a wedge → NPC responds → NEW wheel. Free-text demoted to
      one wedge ("say something else…"); persuasion wedges route through persuade(tone) with C1b odds shown.
      - ~~C2a~~ ✅ 2026-07-05 → ROADMAP #158 (no native radial exists — drew our own; positioned-tables
        recipe with file:line cites; ONE-FRAME-PER-LAYER engine lesson banked).
      - C2 v1-v3 ◐ EXECUTION-PROVEN 2026-07-05 → ROADMAP #158 + #159 (v3 = Ken's final shape: native
        wheel resident across turns, invisible output-only overlay, ME palette, *asterisk* stage
        direction, input-in-slot on option 4). REMAINING: Ken's EXPERIENCE verdict · C2-POLISH unit:
        `open_conversation_menu` signature research → wheel re-render on reply (kills label lag + late
        type-slot restore) · empty-SEND feedback · END placement · then C1b odds on stakes wedges.
        **DEFERRED (Ken 2026-07-05: "that is UI work we can do later") — the whole C2-POLISH unit +
        remaining C-chain UI parks here until called; non-UI lanes (C1b engine half, N/E/P/S, unified
        spec phases) take priority.**
      EXPERIENCE gate: Ken holds an entire conversation wheel-only, radial on screen.
    - C3 `spec'd` DIALOGUE TREE STATE (serves C2): multi-turn conversation state in the BRIDGE (node/branch
      per conversation_id; flags → whitelisted effects only). Interrupt prompts as timed ui events (ME2).
    - C4-C6 `deferred polish` (de-prioritized by the same re-scope — wheel first, cinema later): C4 staging
      (control lock, pacing, ducking) · C5 camera (RESEARCH FIRST via #149 catdat: how vanilla Timelines
      stages scenes) · C6 voice (Player2 TTS, governor color class). None block C1-C3.
  - **T — NAMED COMMAND CAST (blueprint §11 tiers + §5.9 death/succession).** RECONCILE: NO existing leader
    registry — this is the one genuinely greenfield chain. The 35% social half lives here.
    - T1 `spec'd` LEADER REGISTRY: leaders table (id, faction, tier, name, personality, bound_entity_id,
      is_alive) + deterministic Tier-2 admiral generation bound to REAL XL hulls the fleet census already
      tracks. Selftest: bind/rebind/orphan cases.
    - T2 `spec'd` TIER-ROUTED CHAT: contacting a bound hull routes to its admiral persona (one Player2 NPC
      per leader); tier gates LLM usage through the EXISTING governor classes (Tier 0 = canned, zero calls).
    - T3 `spec'd` DEATH & SUCCESSION: kill-event ingest (already live for hostile_events) on a bound hull →
      leader dies, successor generated with degraded morale memory, importance-5 world_event + narrator
      obituary ("Admiral lost aboard <hull>"). Capital losses get narrative weight. EXPERIENCE gate: Ken
      reads the obituary in the news.
    - T4 `spec'd` TIER-0 CANNED LAYER: faction-flavored template responses for generic contacts — believability
      at zero joules.
  - **P — FACTION-TO-FACTION DIPLOMACY ROUNDS (§3.7 / Phase 12).** RECONCILE: EXTENDS seek_ceasefire (#124) +
    create_or_update_agreement + the negotiation selftest surface. Scheduled slow round (piggyback the decision
    cadence): two AI factions with live grievances exchange BOUNDED proposals (ceasefire / pact / tribute),
    each side's Player2 persona choosing in-set from deterministic terms; outcomes land as agreements; narrator
    reports the summit. War fatigue input = war_losses window (exists). Player is notified, may be named envoy
    (bridge to D). DARK behind `diplomacy_rounds_enabled`.
  - **S — SHIP-IT (Phase 13 packaging — grind, not risk).** Profiles = PRESETS over the already-runtime-tunable
    governor + tier enables (Potato/Normal/High/Experimental per blueprint §19, incl. per-session joule budget);
    first-launch status surface (§5.1 five readable states — watcher brief already computes most); install.md +
    troubleshooting.md + disable-safely for a NORMAL user (no dev harness); DB backup note. Last before any
    public release; blocked on nothing.
- ~~G4a escort binding~~ ◐ SHIPPED 2026-07-02 → ROADMAP #93 (real freighter + objective.escort guidance +
  proximity-gated RML_Escort to the AO + loss→hostile_event; objective.custom null-string killed). In-game
  verify: accept an escort contract post-reload.
- **FRAGO push to active player contracts** `spec'd` blocked(G3,G4) — operation frago_issued events for ops with
  player-claimed jobs → drain `contract_frago` → Lua ui event → MD updates the accepted mission cue
  (set_objective/update_mission: new objective line + reward bump) + comm-link ping "FRAGO from <faction> High
  Command" + report row. The "element under command" moment — situation changes reach the player MID-MISSION.
- **#75 G — mission offers over market_jobs** (parent; Ken decision 2026-07-01, spec in ROADMAP #75)
  - ~~G1~~ ✅ 2026-07-01 → ROADMAP #75-G1 (offers/claim routes live, selftest 4/4→7/7)
  - ~~G2~~ ✅ 2026-07-01 → ROADMAP #75-G2 + wiki [[mission-offer-recipe]] (custom create_offer path; the
    cross-script cue-ref idea was falsified)
  - G3 `in-progress ◐` (ROADMAP #75-G3) — offers LIVE ON SCREEN (correct rewards, briefing, Accept renders).
    ONE open link: event_offer_accepted child-cue never fires → refactor to vanilla's ShowOffer shape (top-level
    listener on stored $OfferCue via Registry). Prove: accept → ACCEPTED debug line → /api/jobs status=claimed.
    START HERE.
  - ~~G4 / R-row builds~~ 🏁 BUILD COMPLETE 2026-07-02 → ROADMAP #88-#117: ALL 11 Tier-1 mission types exist
    (2 PAID, 9 wired — scoreboard: wiki [[opord-mission-requirements]]; per-verb runbook:
    [[adding-a-mission-verb]]). REMAINING under this banner: in-game flights per row (#97 standard) ·
    FactionRelations_Changed guard (gm_escort:934 shape) · FRAGO structured amendments (objective/reward
    delta) · task_verb + deliver-amount as first-class job columns (one schema touch, with the A4 slice-2
    tail: Player2 picks the verb from legal_verbs at routing).
  - G5 `◐` — DONE 2026-07-02: escalation repricing (ROADMAP #90, withdraw+re-offer, unit-proven) · NPC-claim
    withdrawal (covered by the gone→withdraw path, #90) · abort/release lifecycle (#84/#85/#89) ·
    **GHOST-OFFER residue root-caused + Orphan_check self-validation cue (ROADMAP #127, ◐ — Forge-clean,
    in-game convergence pending Ken's /refreshmd + quicksave→quickload; kills the /refreshmd-wipes-registry ×
    /reloadui-wipes-tracker duplicate generations)**. REMAINING: verify board==poll-set in-game (flips #127 ✅),
    expiry-vs-job-row policy, desc money formatting (cosmetic), residue purge of non-job rows (LGV-705 orphan
    lease · stance_probe_* saves · freq_b8eee7a420 — needs a safe admin route; never raw-write the live DB)
  - G6 `spec'd` blocked(G4,G5) — E2E in-game gate: see offer → accept → complete → PAID (screenshots; player
    credits up + faction budget_spent up + ledger row) → #75 ✅

## Open (bridge/dashboard)
- ~~G3c~~ ✅ 2026-07-01 → ROADMAP #78 (doctrinal SMESC subparagraphs — Enemy/Friendly/Constraints, doubled
  mission, concept of ops from the real #65 opord_json, repair/salvage, Command a./Signal b. — all from live
  data; in-game render rides next reload). Deferred nicety: warning-order → offer teaser (WNGO already exists).
- ~~E~~ ✅ 2026-07-02 → ROADMAP #139 (freshness selftest 5/5 · live route · browser-rendered panel confirmed).
- ~~D~~ ✅ 2026-07-02 → ROADMAP #103 (all temp diags + navtest + test_frago stripped; lifecycle evidence
  lines + LUAV marker deliberately kept)
- CI-gate hardening `spec'd` — consider full-suite nightly vs fast-subset per reload (watch reload latency);
  gate activates when Ken restarts the watcher window

## L — LLM spend (post-incident follow-ups; governor SHIPPED ✅ 2026-07-02 → ROADMAP #129, selftest 8/8)
- ~~class-aware gate (chat priority · color allowance · test lock)~~ ✅ 2026-07-02 → ROADMAP #130
  (budget_selftest 13/13; NEW SOURCES RULE: any new npc_complete call site must add its source_mod to the
  gate's class sets in player2_client — grep _LLM_COLOR_SOURCES).
- `spec'd` deeper demand-side: daemon cadence audit (fewer color calls WANTED — Bannerlord's 8-call bar).

- ~~ESCORT PACING~~ ✅ RESEARCH CLOSED 2026-07-02 → ROADMAP #149 (vanilla parity proven from extracted
  rml_escort.xml — same library, same orders; not a defect). Optional polish `spec'd`: escort bind-preference
  for M-class traders over L (faster convoys) when the assessment offers both.
- NARRATOR-COVERAGE GATE `spec'd` (AAR #148, mechanical fix for a twice-recurred coupling): selftest check
  asserting every add_world_event kind emitted at importance≥3 appears in narrator _WORTHY_TYPES.

## Small / cleanup
- `spec'd` (#166 demo): OBSERVABILITY GAP — `/api/relationships` (canon-merged) reports a DIFFERENT
  resentment than the engine's raw `relationships` table that `get_relationship`/willingness read. A
  false-flag demo on antigone→paranid showed API resent "0" while the engine already had 9 → the tipping
  point couldn't be shown (pair was pre-poisoned + at anti-spiral cap). Fix: one authoritative resentment
  surface, or make /api/relationships expose BOTH canon and raw. Also: anti-spiral daily cap (~+9) blocks
  a clean tipping-point demo — a `?reset_emotions=` or throwaway-pair dev affordance would help.
- `spec'd` (#163): D2 envelope must also gate the /api/ops/persuade dev door (cooldown+daily live only
  in the chat seam today — probes bypassed them).
- `spec'd` (#161 probe): persuasion refusal reasons must be DIRECTION-AWARE (friendly-ask + low-fatigue
  currently prints the hostile-ask wording, inverted meaning). Per-direction reason map in
  persuasion_willingness + one selftest check per direction.
- `spec'd` (#160 ◐): demand_proof → REAL proof-job via the job door (spec §7.6) · hard authority-role
  gate on persuasion intents (deferred until T-chain personas carry machine-readable authority — today
  the persona redirect prose + engine verdict coexist, playability preserved).
- `spec'd` (AAR #125): /api routes requiring save_id should 400 on empty instead of silently matching nothing
  (WHERE save_id='' returned [] — looked like "no jobs" during live-defect triage), or default to the
  most-recently-active save from /api/memory/saves.
- `spec'd` TOOLING (AAR #123): watcher CI-gate catch block — on selftest failure, read the 500 response body
  (Invoke-RestMethod throws on 500; catch has the response) and log the failing check names + first trace line
  to ci_gate.log instead of bare "(unreachable)". A RED line should be actionable without a browser fetch.
- Verify complete_job's trust +3 fired for job_8dcf98ca2f (antigone reads -2 post-completion where +1 expected;
  check the claimant plumb through Lua ContractCompleted → /v1/job/complete → complete_job)
- Confirm antigone budget_spent bumped on the dashboard for the #97 payout (the /api/factions probe returned {})
- Verify stance pass-through in-game after next reload (one aggressive-type task) — closes ROADMAP #72 ◐
- Purge residue: orphan lease LGV-705 (pre-fix, status 'issued'), `stance_probe_*` save rows, empty force_request
  `freq_b8eee7a420`, forced test op op_argon_6d827f1a1d/task_6fb9d6cbfb (now a real running order — keep/kill?)
- Consider a proper stance column on operation_tasks when a COA type needs a non-derivable posture (#72 tail)

## Watch
- #70b unexplained window: one reload where opord_assign UI events didn't reach MD while other UI events worked —
  if it recurs, add a Lua-side log around AddUITriggeredEvent and compare first-poll-after-load vs later polls
