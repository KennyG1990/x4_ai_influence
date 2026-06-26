# 🌌 AI Influence: The Strategic Mind of the X4 Universe

[![X4: Foundations](https://img.shields.io/badge/X4%20Foundations-Extension-blue.svg?style=for-the-badge&logo=steam)](https://www.egosoft.com/)
[![Requires](https://img.shields.io/badge/Requires-Neural%20Link%20Bridge-red.svg?style=for-the-badge)](https://github.com/)
[![AI Backend](https://img.shields.io/badge/Powered%20By-Player2%20AI-purple.svg?style=for-the-badge)](https://github.com/)

> **"The Argon Federation recorded your assistance defending our miners last week, Commander. But we also recorded your attack on our convoy yesterday. Trust is not restored by a single good deed. If you want peace, it will cost you."**

---

## 📝 DESCRIPTION

**AI Influence** is a comprehensive gameplay modification for *X4: Foundations* that adds real-time artificial intelligence to manage dialogues, faction diplomacy, and dynamic events in the universe. 

The mod turns static faction representatives, fleet commanders, and station officers into living characters with memory who remember your previous interactions, react to major battles and sector takeovers, and dynamically adapt their behavior based on the simulated state of the galaxy.

> [!TIP]
> **Key Feature:** All dialogues are generated in real-time using local AI. Every conversation is unique, depending on the current simulated world state, your relationship with the NPC, and the history of your interactions.

---

## ✨ FEATURES & PLAYABLE SYSTEMS

### 🤖 AI Dialogues with Faction Leaders
* **Dynamic Real-Time Chat:** Hold natural language conversations with key figures (like Administrator Nerra of the Argon Federation). Type your own messages or pick from dynamically generated dialogue suggestions.
* **Universe-Aware Context:** NPCs know about current sector ownership, which factions are at war, your active credits, and nearby fleet strengths.
* **Trust & Leverage System:** Factions calculate your economic and military importance. If your mega-factories supply their shipyards, they will treat you as a strategic partner; if you supply their enemies, they will react with suspicion or hostilities.
* **Optional Voice Acting:** Supports text-to-speech (TTS) via Player2, bringing faction representatives to life with spoken dialogue.

### 🌍 Dynamic Galactic Events & News
* **Living Bulletin Boards:** The AI generates news bulletins, alerts, and detailed strategic statements based on actual simulated events (like a faction losing a Destroyer or a shipyard running out of Hull Parts).
* **Player Communiqués:** Factions can reach out directly to the player with urgent requests, warnings, or trade offers that appear as logbook notifications.
* **History Articles:** Read narrative accounts of sector capturing, economic collapses, and political truces as they unfold across the jump gates.

### ⚔️ AI Faction Diplomacy
* **Automated Faction Relationships:** AI faction leaders make strategic statements about wars, peace treaties, and alliances based on computed "war fatigue" and military balance.
* **Negotiated Ceasefires:** Talk your way out of hostilities. Pay reparations, trade goods, or promise military assistance to raise your reputation score back into the peace zone.
* **Territory Transfers:** Negotiate sector rights and access to exclusive shipyard building berths as part of peace terms.
* **War Statistics:** The AI tracks ship losses, sector control, and conflict durations, which direct whether faction heads seek truce or double down on war.

### ⚙️ Interactive AI Command System
Order allied fleets and coordinate strategic moves directly through dialogue. The AI parses your requests and issues whitelisted native commands to existing assets (no cheat spawning):
* **Patrol Sector:** Command a faction's combat fleet to move and defend a strategic sector.
* **Raid Station:** Request military assets to initiate an assault on an enemy station.
* **Economic Trade Aid:** Arrange bulk ware transfers with stations (safely monitored by anti-cheat guards).
* **Relation Shifts:** Coordinate joint declarations of war or peace.

### 💬 SQLite Memory Database
* **Durable Interaction Logs:** Each leader has a personal memory file in an external SQLite database (`kilo.db`).
* **Continuous History:** NPCs remember your past oaths, agreements, and betrayals.
* **Memory Consolidation:** Dialogue transcripts are summarized into distinct facts, preventing slow response times while ensuring long-term continuity across your playthroughs.

### 📜 Capital Loss & Succession Chronicles
* **Commanders of Weight:** Tier 2 admirals and commanders are bound to physical L and XL capital ships.
* **Succession Stories:** When an important flagship is destroyed in battle, the event is logged. The successor assumes command, the crew reacts to the loss, and the incident is recorded in the faction's memory history.

---

## 🎭 15 Tales from the Frontier: What Will Your Story Be?

No matter how you choose to play X4, AI Influence reshapes your journey. Close your eyes, fire up your warp drive, and imagine what could happen:

### 1. The Industrial Tycoon (The Megabuilder)
> You control a sprawling factory network in Second Contact, churning out Hull Parts and Claytronics. The Argon Federation's shipyard is stalled under heavy Xenon pressure. The Argon Liaison contacts you: they notice your production capacity and propose a priority supply contract. In exchange, they offer to lease you exclusive Capital Ship building berths.

### 2. The Shady Smuggler (The Scoundrel)
> The Teladi Ministry of Finance intercepts your freighter carrying a hull full of Space Weed. Instead of an automated fine and a reputation hit, the commanding officer opens comms. He's greedy. You negotiate: a massive bribe under the table, or a promise to feed him intel on the Split Zyarth shipping schedules in his sector.

### 3. The Mercenary Admiral (The Combat Specialist)
> You command a private fleet of three Colossus Destroyers. A desperate Paranid military commander, facing an imminent invasion at the sector gate, offers to hire your fleet. You bargain for credit-per-hour rates, negotiate hazard pay for capital ship damage, and contract your ships as a frontline blockade.

### 4. The Fanatical Loyalist (The Zealot)
> You take a blood oath to the Holy Order of the Pontifex. You speak to the Priest-Duke, agreeing to blockade the Antigone Republic's borders. He promises that if you hunt down 10 Antigone trade ships, he will personally unlock the schematics to their classified weapon systems.

### 5. The War Profiteer (The Opportunist)
> You play both sides of the Paranid Civil War, supplying advanced electronics to both factions. When the Godrealm discovers your double-dealing, they threaten to blockade your trade lanes. You must hold a tense conversation with the High Priest to explain your actions, bribe their anger away, or face war.

### 6. The Deep-Space Cartographer (The Explorer)
> While exploring the uncharted outer sectors, you locate a massive, abandoned derelict ship and map out rich, untouched silicon fields. Instead of selling it to a generic station board, you negotiate in a local trade station bar to sell the coordinates to the highest bidding faction representative.

### 7. The Shipyard Magnate (The Fleet Supplier)
> You build a massive, independent shipyard. Instead of passive buyers, factions actively approach you. The Split Zyarth Patriarchy requests a batch of custom-fitted corvettes for their war effort. You bargain over build specifications, delivery timelines, and payment structures.

### 8. The Peaceful Merchant (The Pacifist)
> A Teladi CEO demands a new "protection tariff" on your local trade loops. Rather than fighting, you use your leverage: you negotiate a trade pact to lower the tariffs in exchange for supplying the raw materials for their new defense platform projects.

### 9. The Xenon Hunter (The Protector)
> You dive into a sector battle and single-handedly disable a Xenon K Destroyer. The local patrol captain opens comms to thank you. This heroic act builds a personal friendship. Ten hours later, when you get ambushed by pirates in that sector, you call that captain for immediate backup, and he remembers his debt.

### 10. The Syndicate Target (The Rebel)
> You have been raiding Vigor Syndicate supply lines, and their hit squads are hunting you. You coordinate a meeting with a Syndicate underboss in a shady station bar. You sit down to negotiate a truce, bargaining over territory boundaries and tribute payments to call off the bounty.

### 11. The Mining Baron (The Industrialist)
> Your mining fleets in Grand Exchange are constantly harassed by Kha'ak swarms. You contact the local Teladi sector patrol. You negotiate a contract: you will supply their stations with discounted ore and gas, and in return, they will assign two combat wings to escort your miners.

### 12. The Border Mediator (The Diplomat)
> Tension is boiling over between the Antigone Republic and the Terran Protectorate. You step in as a third-party mediator, negotiating terms with representatives from both sides to establish a demilitarized buffer zone in the frontier sectors.

### 13. The Xenophobic Terran (The Purist)
> Playing as a Terran fanatic, you intercept a Commonwealth pilot entering the asteroid belt. You interrogate them, warning them in no uncertain terms that they are violating Sol airspace, demanding they dump their cargo and turn back, or face Terran justice.

### 14. The Underdog Survivor (The Scrapper)
> You start the game with a single, battered fighter, having lost everything to a pirate raid. You land at a station and beg a local faction representative for a basic loan or a starter ship, pledging your combat services to pay off the debt over time.

### 15. The Master Conspirator (The Traitor)
> You sign a non-aggression pact with Split Zyarth, but secretly fund the Free Families rebellion. When Zyarth notices where the rebel weapons are coming from, they summon you to explain. You must lie, deflect, and use your diplomatic charm to convince them of your innocence.

---

## 🔒 Play Safe: Bounded AI & Save Protection

We know how much players value their long-term save files. AI Influence is built from the ground up to protect your game:
* **No Magic Resource Spawns:** The AI cannot spawn ships or resources out of thin air. Commands utilize existing simulated assets.
* **External Sandbox Memory:** Memories are stored in an external database, keeping your X4 save files clean, lightweight, and completely uncorrupted.
* **Idempotency Guard:** Every command carries a unique transaction ID, preventing duplicate credit deductions or relation shifts.
* **Fail-Safe Offline Mode:** If your AI bridge is offline or runs out of energy, the mod automatically falls back to canned, faction-appropriate dialogue templates. **No crashes, no freezes.**

---

## 🚀 Quick Setup Guide

### 📋 Prerequisites
1. **X4 Foundations** (v6.00 or newer).
2. **Player2 Desktop AI App** (downloadable at [https://player2.game](https://player2.game)).
3. The **X4 Neural Link** extension installed (`x4_neural_link`).
4. The **djfhe_http** extension installed (carries the HTTP signals).

### 📥 Installation Steps
1. Unpack `x4_ai_influence` into your X4 `extensions` folder:
   ```text
   C:\Program Files (x86)\Steam\steamapps\common\X4 Foundations\extensions\x4_ai_influence
   ```
2. Run **Player2.exe** and sign in. (You will receive a daily allocation of energy/joules to run the AI backend. For optimal results, selecting a model like QWEN-3 or equivalent is recommended).
3. Start the local server by double-clicking `Start-Neural-Link.bat` in the `x4_neural_link` extension folder.
4. Launch X4: Foundations, load your save file, and press `Shift + C` or walk up to any faction representative and select **"Speak to AI"**.

---

## ❓ Troubleshooting & Support

* **The "Speak to AI" option is greyed out/not appearing:** Make sure both the Player2 App and the Neural Link bridge (`Start-Neural-Link.bat`) are running in the background before you launch X4.
* **The representative doesn't reply:** Ensure your Player2 account has "joules" (AI power) available. If you are out of joules, the mod will fall back to local dialogue options automatically.
