# AGENTS.md

## Project

Godot 4.7 / GDScript — 2D pixel sandbox life sim with LLM-driven AI companion.
Primary language is Chinese (zh-CN) for UI, comments, and config.

## Key files

- Entrypoint scene: `scenes/main.tscn`
- Entrypoint script: `scripts/main.gd`
- All game constants: `scripts/config/game_config.gd` (`class_name GameConfig`)
- LLM config (gitignored): `config/llm_config.json` — see `config/llm_config.example.json`
- AI prompt: `config/ai_prompt.json`
- User data root: `user_data/` (saves, settings, custom roles — all gitignored)
- App path resolution: `scripts/core/app_paths.gd`

## Run

No npm/pip/build step. Open in Godot editor or:

```powershell
& "path\to\Godot_v4.7-stable_win64.exe" --path "D:\.WORKSPACE\with-you.exe"
```

Headless smoke test:

```powershell
& "path\to\Godot_v4.7-stable_win64.exe" --headless --path "D:\.WORKSPACE\with-you.exe" --quit-after 2
```

## Architecture

Single-scene design. `main.gd` creates all nodes in code via `_create_core_nodes()`:
world → player → AI companion → camera → HUD (CanvasLayer) → LLM client → memory store → AI director.

`AI director` (`scripts/ai/ai_director.gd`) is the AI brain — orchestrates perception, LLM calls, action execution, and memory.
`World renderer` (`scripts/world/world_renderer.gd`) owns terrain data, tile overrides, and rendering.
`Save manager` (`scripts/core/save_manager.gd`) handles all persistence (JSON + CSV memory files).

## Config conventions

- All tunable constants live in `game_config.gd`. Don't scatter magic numbers elsewhere.
- LLM credentials: `config/llm_config.json` (gitignored) or `WITHYOU_LLM_*` env vars. Never commit real API keys.
- `game_config.gd` has `normalize_build_kind()` with Chinese aliases (e.g. "木地板" → "wood_floor"). Use it instead of raw string matching.
- Default AI sprite sheet config is duplicated in `ai_role_library.gd` and `ai_companion.gd` — change both or refactor.

## Git / file conventions

- `.godot/` is auto-generated, gitignored. `.import` files are committed (Godot import metadata).
- Line endings: LF (`.gitattributes` sets `* text=auto eol=lf`).
- `user_data/` contains runtime saves/settings, gitignored — don't commit.
- `config/llm_config.json` is gitignored. Only `llm_config.example.json` is tracked.

## Common modification points

| What | File |
|---|---|
| Game params (speeds, radii, timings) | `scripts/config/game_config.gd` |
| AI prompt / persona | `config/ai_prompt.json` |
| AI action protocol & perception | `scripts/ai/ai_director.gd` |
| AI movement, pathfinding, follow, teleport | `scripts/entities/ai_companion.gd` |
| Player movement & input | `scripts/entities/player.gd` |
| World generation (noise, biomes) | `scripts/world/world_generator.gd` |
| Tile rendering & texture fallback | `scripts/world/world_renderer.gd` |
| Sprite sheet / pixel actor drawing | `scripts/visual/pixel_actor_view.gd` |
| Portrait image loading & fallback | `scripts/visual/portrait_view.gd` |
| Save/load format | `scripts/core/save_manager.gd` |
| Memory CSV format | `scripts/ai/ai_memory_store.gd` |
| HUD / UI | `scripts/ui/hud.gd` |
| LLM HTTP client | `scripts/services/llm_client.gd` |

## Gotchas

- `config/llm_config.json` is gitignored — if missing, game falls back to offline placeholder AI.
- Buildable tiles are only `wood_floor`, `stone_floor`, `wood_wall`. `wood_floor` can be placed on water (bridge).
- Blocking tiles: `water`, `wood_wall`, `tree`, `stone_hill`.
- AI perception is local, not global — controlled by `PERCEPTION_MAP_TILE_SIZE` and `PERCEPTION_RAY_TILE_LENGTH`.
- Custom AI roles in `user_data/roles/` still use hardcoded portrait directory (inkbai). Dynamic portrait switching per role is not yet implemented.
- `opencode.json` is gitignored in this repo.
