# Hearthvale

A low-poly **open-world RPG** built with the **Godot 4.6** engine, exported to the web and tuned for **mobile (iPhone) browsers** — Safari, Chrome and Firefox, desktop and mobile.

Explore a central **village hub** with paths leading out in different directions to a **forest**, a **cave dungeon**, and a **mountain pass** — in any order. Scattered skeletons guard a **key** in each outer area; recover all three to break the seal on the final **Sanctum**.

**Play:** open the preview link from the pull request (a Godot Web `nothreads` build).

## Gameplay

- **Village (hub):** talk to Elder Maelin, grab the steel sword from the chest, then head out any of the three open paths. A sealed gate to the south leads to the Sanctum.
- **Whispering Forest** (north) — skeleton minions, the **Verdant Key**.
- **Gloomroot Cavern** (east) — torch-lit dungeon, skeleton warriors, the **Gloom Key**.
- **Frostwind Pass** (west) — a frozen ridge, skeleton rogues, the **Sky Key**.
- **The Sealed Sanctum** (south, locked) — once all three keys are recovered the seal breaks; reach it to win and claim the **Ember Blade**.

Light RPG systems: levels/XP, gold, a health bar, health potions, three weapon tiers, and a quest tracker.

## Controls

| | Touch (phone) | Keyboard / mouse |
|---|---|---|
| Move | drag the **left** side of the screen (on-screen joystick) | **WASD** / arrow keys |
| Attack | **ATTACK** button (bottom-right) | **J** / Enter |
| Interact / talk / open | **USE** button | **USE** button |
| Drink potion | **POTION** button | **POTION** button |

A tap-to-start screen unlocks audio and shows the controls.

## How it's built

- **Engine:** Godot 4.6.3, **Compatibility (OpenGL / WebGL2)** renderer, single-threaded (`nothreads`) web export so it runs in mobile browsers with no special headers.
- **Data-driven world:** the whole world is described in [`world.json`](world.json) + [`quests.json`](quests.json) (loose files served next to `index.html`). Areas and their `.glb` assets **stream from a CDN at runtime**, so the packed game stays small. The streaming/quest systems live in `scene_manager.gd`, `area_builder.gd`, `quest.gd`, `rpg_systems.gd`, `interaction.gd`.
- **Hero & enemies:** a rigged KayKit Knight and skeleton enemies share one `Rig_Medium` skeleton; animations (idle/walk/run/attack/hit/death) are retargeted from shared clip libraries at runtime (`anim_rig.gd`). Cel look via toon materials + an inverted-hull ink outline (`shaders/outline.gdshader`).
- **Art style:** one committed KayKit low-poly style end-to-end (buildings, nature, dungeon, characters), with a lit `WorldEnvironment` (equirect sky, ACES tonemap, fog, shadows, MSAA) and per-area mood (sun/sky/fog/torch lighting). Combat has hit particles, a hit-flash and camera shake.

## Build it yourself

```bash
# Godot 4.6.3 headless + the nothreads web export templates required
./fetch_assets.sh                   # download the bundled hero/animation/sky assets into models/
godot --headless --path . --import
godot --headless --path . --export-release "Web" out/index.html
cp world.json quests.json out/      # loose data, fetched at runtime
# serve out/ over HTTP (wasm needs the right MIME type)
```

## Credits / licenses

- **Characters, animations, props:** KayKit by **Kay Lousberg** — characters CC-BY 4.0, props CC0.
- **Skyboxes:** Screaming Brain Studios (CC0).
- All assets are served from the project's curated asset library; only the hero, animation libraries and sky textures are bundled into the export — everything else streams.

No backend / accounts — Hearthvale is a single-player, locally-run game.
