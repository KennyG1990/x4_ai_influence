# EYEBALL QUEUE — Ken's 30-second in-game confirmations (ADR-G3 EXPERIENCE gates)

> These flip ✅ only on Ken's screen. Each ships with a click-by-click. Machine/EXECUTION side is
> already proven for all of them (cited). Do them whenever; interrupt nothing.

## EG-1 — CONVERSATION EXPERIENCE — ◐ MOSTLY CONFIRMED BY AGENT 2026-07-21 (ROADMAP #196)
**Agent drove a real wheel conversation on screen (bridge stopped):** "Speak to AI" → typed messages →
grounded reply naming the REAL sector ("docked at Hewa's Twin I") + memory recall ("Yes, Commander Vega, I
remember your name"). So intra-session grounding + memory + the serverless opener are SEEN working. **Only
Ken-remaining nicety:** the same in a save→reload cycle within a real wheel conversation (the probe already
proved cross-reload recall bridge-dead, #193d). Script below still valid; expect ~5s replies with the bridge
STOPPED (with the bridge running the direct lane can hang — defect D-B).

### (original EG-1 script)
**What's already proven (machine):** SendDirectChat → Player2 :4315 → reply → in-save card round-trips a
save/reload with the Python bridge KILLED (ROADMAP #193); memory schema selftest 10/10 (#194).
**What only your eyes can confirm:** the reply appears on screen in the chat, and memory persists across a
reload in a REAL conversation (exercises the blackboard identity path the pure selftest can't).
**Script:**
1. Talk to any station Manager (comm/Talk — NOT the dock-services "Trade" menu). In the CONVERSATION
   choices, pick **"Speak to AI"** (added by ai_influence_conversation.xml via vanilla
   add_player_choice_sub — this is the PRIMARY, serverless opener; the dead Shift+C is just a convenience).
2. Type: `Remember my call sign is Nightjar.` → Send. You should see an in-character reply within ~2s.
   (Watch the debuglog for `SendDirectChat token=… SendDirect <= … reply len=…` if you want the trace.)
3. Close the chat. Quicksave (F5), wait, Quickload (F9).
4. Re-open the chat with the SAME manager. Type: `What is my call sign?` → the NPC should answer "Nightjar".
   → flip #193 exp◐ and #194 identity◐ ✅. If it forgets, the blackboard token didn't stick across reload
   (re-open the identity ◐ with that evidence).

## EG-0 — DEAD HOTKEYS = external-Python dependency [ROOT-CAUSED 2026-07-21] — LOW PRIORITY
Shift+C/V/B don't fire because **SirNukes' Hotkey API only works when the external "X4 Python Pipe Server"
is running** (verbatim in content.xml); debuglog confirms `Hotkey_API` never signals (grep = 0).
**Reprioritized DOWN after reconcile:** the PRIMARY chat opener is the conversation "Speak to AI" choice
(ai_influence_conversation.xml, vanilla add_player_choice_sub — already serverless, no pipe). The hotkey is
convenience-only. So this is NOT on the serverless critical path. Options when we get to it: run the
SirNukes pipe (re-adds Python — reject), or drop the hotkey / bind via native X4 input. Deferred.
