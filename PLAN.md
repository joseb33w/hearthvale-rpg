# Goal

A low-poly, mobile-first open-world RPG in Godot 4.6 (Compatibility / WebGL2, `nothreads` web export). A central **village hub** with paths leading out in different directions to a **forest**, a **cave dungeon**, and a **mountain pass** — explorable in any order. Each outer area holds a **key** guarded by scattered enemies; recover all three to break the seal on the **Sanctum** (the final area). KayKit committed art style end-to-end; playable with touch (on-screen joystick + buttons) and keyboard/mouse.

# World design (data-driven `world.json` + `quests.json`, streamed)

- `village` (start hub, safe): elder NPC, starter-gear chest, KayKit `kk_hex` buildings (castle landmark, tavern, blacksmith, church, market, homes, well). Open paths North→forest, East→cave, West→mountain; a **sealed South gate** to the Sanctum (locked by the `seal_broken` flag).
- `forest`: skeleton minions, dense `kk_nature` trees/rocks/bushes, chest with the **Verdant Key**.
- `cave`: skeleton warriors, `kk_dungeon` walls/columns/torches (lit), chest with the **Gloom Key**.
- `mountain_pass`: skeleton rogues, rocky/snowy, ancient stones, chest with the **Sky Key**.
- `sanctum` (goal `reach_area`): `fs_temple` pillars + banners, two guardian skeletons, a victory keeper + treasure.
- Quest `recover_relics`: collect the three keys → sets `seal_broken` → unlocks the Sanctum gate. Winnability gated by qgcheck.

# Files to touch

- `world.json`, `quests.json` — the 5-area world + 3-key quest graph.
- `main.gd` — real KayKit Knight hero (retargeted idle/walk/run/attack from the `kk_rig_medium` libraries) with toon materials + ink outline; SpringArm follow-cam; full `WorldEnvironment` (packed equirect sky, ACES, fog, shadows, MSAA); combat JUICE (hit particles + flash + camera shake); responsive HUD with visible joystick + safe-area insets; tap-to-start overlay.
- `area_builder.gd` — per-area themed kits, scatter sets, `enemy_type` mapping, torch OmniLights, procedural-noise ground, derived box colliders.
- `enemy.gd` — retarget streamed skeletons (no embedded clips) via the shared anim libraries; per-type stats.
- `anim_rig.gd` (new) — shared Rig_Medium retarget helper.
- `shaders/outline.gdshader` (new) — inverted-hull ink outline.
- `rpg_systems.gd` — item catalog (the three keys + gear).
- `export_presets.cfg` — add `viewport-fit=cover` for iOS safe-area.
- Packed into `res://models/`: `kk_Knight.glb` + three `kk_rig_medium_*` clip libraries + two equirect sky PNGs. Everything else streams from R2.

# Verification approach

- qgcheck winnability gate must PASS (reachable 3-key → flag → sealed-gate chain).
- Headless smoke verify (engine boots, canvas, clean console, frames) + screenshot critique vs the KayKit style.
- Targeted checks: hero facing (drive W then S), combat delta + visible juice, enemy chase/attack, trigger/seam firing (collision layer/mask), clip resolution (no T-pose), mobile fill at portrait + landscape.
- Independent QA specialist pass before the PR.

# Out of scope

- Audio (no sound assets bundled this pass) — tap-to-start overlay is wired for a future audio-unlock.
- Save/load persistence (no backend; this is a single-player local game — task scoped no-backend).
- Seamless open-world chunk streaming (using connected zones, per the template).
