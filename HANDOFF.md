# HANDOFF — x4_ai_influence (in-game MD/Lua side)

> Updated 2026-07-01. Supersedes the 2026-06-30 version (which described the mid-UI-build state — that phase is DONE).
> The authoritative cross-session memory is `x4_ai_influence/docs/ROADMAP.md` (moved 2026-07-22; x4_neural_link is deprecated). The full project handoff is
> `handoff-fable-2026-07-01.md` (architecture, workflow, gotchas) — read that first if you have it.

## State (2026-07-01)

The mod is BUILT and deployed. All backlog tasks #1–#67 closed; 22/22 bridge selftest suites green.
- `md/` — 10 cue files: `ai_influence_worldsync.xml` (15s heartbeat, world-state IN), `ai_influence_contract.xml`
  (the `On_action` actuator: `adjust_relation → set_faction_relation`, economy, military), `ai_influence_galaxynews.xml`
  (drain news → logbook per category), `ai_influence_conversation.xml` + `ai_influence_chat.xml` (chat),
  `aic_opord_execution.xml`, `ai_influence_combat.xml`, `ai_influence_hotkey.xml`, `ai_influence_main.xml`,
  `ai_influence_proving.xml`.
- `aiscripts/order.aic.opord.protectposition.xml` — OPORD military order.
- `ui/addons/ai_influence_chat/aic_uix.lua` — polls `/v1/influence_drain` each heartbeat; dispatches
  `news → log_<category>` and `actions[] → 'action'` MD events (the drain→game bridge).
- `config/action_whitelist.json` — enabled: dialogue_only, memory_write, logbook_entry, status_update,
  relation_delta_limited. Gated: credit_transfer_limited, mission_offer, trade_request, temporary_diplomatic_flag,
  faction_to_faction_proposal. Mirror changes into the embedded DEFAULT in `bridge/actions.py`.

## Rules

- **MD is authored/validated through the X4 Forge** (F:\DEV_ENV\X4_Forge, http://localhost:3000) — UI or agent API
  (`/api/agent/project/validate` etc., see the `x4-forge-api` skill). Never claim MD legal without a Forge validate.
- Architecture: Player2 proposes intent/actions; bridge + MD validate, whitelist, execute. Failed/unparsed Player2
  decisions DEFER — never math-fallback. No player-facing feature is ✅ until seen in-game (◐ = bridge-verified only).
- **NEVER hardcode a save_id anywhere (docs, code, tests, scratch).** Ken starts new save files at will to prove new
  logic against clean data, so any recorded id (e.g. in old ROADMAP entries) is historical, not current. ALWAYS
  resolve the active save live: `GET http://127.0.0.1:8713/api/memory/saves` → most-recent `last_active_ms`.
- Live extension mount forbids deletes — overwrite/truncate, never delete. `.forgekeep` protects the bridge on deploy.
- WORKFLOW v2 (2026-07-01): agents NEVER run git — commits are Ken's own via Antigravity (ROADMAP close title =
  suggested message); read BACKLOG.md first; decisions.md (ADRs) checked during reconcile; significant diffs
  cross-model reviewed. Authoritative: F:\DEV_ENV\CLAUDE.md.

## Frontier

On-screen in-game confirmation (the one recurring ◐): foreground X4, let the daemon's strategic tick fire, and SEE
in the logbook an "Overheard —" scene line, a negotiation verdict, and a relation shift. Then flip ◐ → ✅.
