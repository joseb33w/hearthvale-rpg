#!/usr/bin/env bash
# Download the BUNDLED assets (hero, animation libraries, sword, skyboxes) into models/.
# Everything else (village buildings, nature, dungeon props, skeleton enemies, NPCs) streams
# from the asset CDN at runtime, so only these few are packed into the web export.
set -euo pipefail
BASE="https://preview.myapping.com/godot-assets"
mkdir -p models
dl() { curl -sfL "$BASE/$1" -o "models/$(basename "$1")" && echo "  ok $(basename "$1")"; }
dl characters/kk_Knight.glb
dl animations/kk_rig_medium_general.glb
dl animations/kk_rig_medium_movementbasic.glb
dl animations/kk_rig_medium_combatmelee.glb
dl props/kk_weapons/sword_A.glb
dl skies/sb_cloudy_1.png
dl skies/sb_cloudy_3.png
echo "Assets ready. Next:  godot --headless --path . --import"
