# HANDOFF — x4_ai_influence mod build

> Paste the prompt below into a new session to resume. Updated 2026-06-30.

---

Continue building the x4_ai_influence mod (the in-game MD/Lua side) inside the X4 Forge UI.

READ FIRST (your cross-session memory):
- F:\DEV_ENV\projects\Mods\X4Mods\x4_ai_influence\x4_neural_link\ROADMAP.md
  → see the "UI-BUILD GRADUATION LOG" section at the top for exactly where we are.
- The x4-forge-editor skill (anthropic-skills:x4-forge-editor). CRITICAL: wiring is
  CLICK-TO-CONNECT (click source terminal → "LINKING TERMINALS" banner → click destination
  terminal), NOT drag. Dragging just moves the node.
- Reference mod (kept for this purpose): F:\DEV_ENV\projects\Mods\X4Mods\ai_influence_test\
  (md\ai_influence_test_chat.xml, _contract.xml, _main.xml, ui.xml) — ground every cue against it.

HARD RULES (enforce 100%, in F:\DEV_ENV\CLAUDE.md):
- Build/author through the Forge agent API or files as needed; the old UI-only mandate is lifted.
- Clean rename test→real: build in the clean `ai_influence` namespace (not ai_influence_test). Keep
  ai_influence_test installed as reference.
- Update the correct ROADMAP at the END of every task (mod/bridge → Neural Link ROADMAP; Forge-codebase → Forge
  ROADMAP). Keep them separate.
- Follow the 2026-06-30 Bannerlord-proven Player2 action architecture: Player2 proposes intent/actions; Neural
  Link/X4 validate, whitelist, execute, and prove. No game-state action is ✅ until it is seen in-game.

GOVERNING ACTION PATTERN:
`X4 context -> bridge -> Player2 JSON {response/reply, actions[]} -> bridge audit/normalize -> X4 validator -> MD/Lua execution`.
Player2 owns voice, preference, doctrine-flavored judgment, and proposed actions. X4 owns facts, legality, bounds,
cooldowns, object lookup, execution, and proof. Failed/unparsed Player2 decisions defer; they do not math-fallback to
a real action.

DONE + VERIFIED so far (UI-only, COMPILER OK):
- Chat_boot + Poll_tick heartbeat cue, matches reference exactly (event_game_loaded →
  set_value $booted; sub-cue Poll_tick: delay 1s → raise_lua_event 'AIChat.poll' → reset_cue).

NEXT (in order):
1. Finish ai_influence_chat: the Open_chat library (raises 'AIChat.open') + Auto_open is
   test-only, decide whether to drop it. Then the conversation cues.
2. ai_influence_contract: the scalar-event dispatch cues (act_faction/act_target/act_go).
3. worldsync cues. Then the Lua/UI side (HUD & LUA UI tab). Then content.xml identity + deps
   (djfhe_http, ws_3477279743, ws_2042901274). Then COMPILE & DEPLOY (preserve x4_neural_link).

Forge tab: http://localhost:3000 (MD SCRIPTS tab, preset X4_AI_Influence). Note: `reset_cue` and
some actions aren't in the node palette — author those as Custom XML Action nodes (they still
validate against md.xsd). Start by reading the roadmap, then open the Forge and continue at step 1.
