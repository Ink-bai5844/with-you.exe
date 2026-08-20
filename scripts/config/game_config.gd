class_name GameConfig
extends RefCounted

const TILE_SIZE = 16
const ACTOR_COLLISION_TILE_RATIO = 0.8
const ACTOR_COLLISION_BOTTOM_Y = 8.0
const ACTOR_COLLISION_MOVE_STEP = 4.0
const CITY_SIZE = 99
const CITY_HALF_SIZE = 49

const DEFAULT_WORLD_SEED = 47029
const START_GAME_MINUTES = 8.0 * 60.0
const GAME_MINUTES_PER_REAL_SECOND = 1.0

const PLAYER_SPEED = 96.0
const AI_SPEED = 78.0
const AI_FOLLOW_TELEPORT_DISTANCE = 384.0
const AI_FOLLOW_STUCK_SECONDS = 3.0
const AI_FOLLOW_STUCK_MIN_SPEED = 2.0
const AI_FOLLOW_TELEPORT_SEARCH_RADIUS = 5
const AI_FOLLOW_TELEPORT_COOLDOWN_SECONDS = 2.0
const AI_MOVE_STUCK_SECONDS = 2.5
const AI_MOVE_STUCK_MIN_SPEED = 2.0
const AI_MOVE_TELEPORT_SEARCH_RADIUS = 4
const AI_MOVE_TELEPORT_COOLDOWN_SECONDS = 1.5
const AI_PATH_MAX_NODES = 20000
const AI_PATH_SEARCH_MARGIN = 48
const CAMERA_ZOOM = Vector2(2.5, 2.5)
const AUTOSAVE_REAL_SECONDS = 180.0
const TILE_KIND_CACHE_LIMIT = 16384
const CHAT_LOG_LIMIT = 200
const LLM_LOG_LIMIT = 160
const AREA_SELECTION_MIN_DRAG_PIXELS = 12.0
const MEMORY_SAVE_DEBOUNCE_SECONDS = 0.45
const FORGET_MIN_MEMORIES = 8
const HUNGER_PER_GAME_MINUTE = 0.05
const ENERGY_MOVE_PER_SECOND = 4.0
const ENERGY_REGEN_PER_SECOND = 6.0
const ATTRIBUTE_MAX = 120.0
const DEFAULT_AI_PORTRAIT_DIR = "res://assets/characters/inkbai/portraits"
const DEFAULT_MOBAI_SPRITE_SHEET = {
	"path": "res://assets/characters/inkbai/sprites/inkbai-move.png",
	"columns": 12,
	"rows": 1,
	"frames_per_direction": 3,
	"fps": 6.0,
	"idle_frame": 0,
	"walk_sequence": "2131",
	"frame_width": 55,
	"draw_size": [27, 41],
	"bottom_y": 12.0,
	"direction_frames": {"down": 0, "right": 3, "left": 6, "up": 9},
}

const DEFAULT_RESOLUTION = Vector2i(1920, 1080)
const DEFAULT_WINDOWED_RESOLUTION = Vector2i(1280, 720)
const WINDOW_DECORATION_FALLBACK = Vector2i(16, 40)
const WINDOW_MODE_WINDOWED = "windowed"
const WINDOW_MODE_FULLSCREEN = "fullscreen"
const RESOLUTION_OPTIONS = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

const PERCEPTION_INTERVAL_GAME_MINUTES = 60.0
const PERCEPTION_MAP_TILE_SIZE = 10
const PERCEPTION_RAY_TILE_LENGTH = 15
const AI_ACTION_RESULT_TRIGGER_PERCEPTION = true
const RECENT_HISTORY_LIMIT = 12
const MEMORY_RECALL_COUNT = 8
const FORGET_INTERVAL_GAME_MINUTES = 60.0
const FORGET_PERCENT = 0.01

const DEFAULT_PLAYER_INVENTORY = {"wood": 24, "stone": 8}
const DEFAULT_AI_INVENTORY = {"wood": 16, "stone": 6}
const AI_INVENTORY_VIEW_DISTANCE_TILES = 3
const AI_ITEM_TRANSFER_DISTANCE_TILES = 3
const PLAYER_BUILD_RADIUS = 2
const TERRAIN_TILE_KINDS = ["city", "city_border", "grass", "plain", "water", "tree", "stone_hill"]
const BUILDABLE_TILE_KINDS = ["wood_floor", "stone_floor", "wood_wall"]
const WATER_BUILDABLE_TILE_KINDS = ["wood_floor"]
const BLOCKING_TILE_KINDS = ["water", "wood_wall", "tree", "stone_hill"]
const BUILD_COSTS = {
	"wood_floor": {"wood": 1},
	"stone_floor": {"stone": 1},
	"wood_wall": {"wood": 2},
}
const BUILD_REFUNDS = {
	"wood_floor": {"wood": 1},
	"stone_floor": {"stone": 1},
	"wood_wall": {"wood": 2},
}
const TERRAIN_DESTROY_DROPS = {
	"tree": {"wood": 3},
	"stone_hill": {"stone": 4},
}
const TERRAIN_DESTROY_REPLACEMENTS = {
	"tree": "plain",
	"stone_hill": "plain",
}

const DEFAULT_LLM_BASE_URL = "https://api.openai.com/v1"
const DEFAULT_LLM_MODEL = "gpt-4.1-mini"
const DEFAULT_LLM_COMPRESS_MODEL = "gpt-4.1-mini"
const DEFAULT_LLM_TIMEOUT_SECONDS = 120.0
const DEFAULT_LLM_MAX_RETRIES = 2
const DEFAULT_LLM_RETRY_DELAY_SECONDS = 2.0

const MOODS = ["calm", "happy", "curious", "worried", "tired", "angry", "disappointed", "sad", "annoyed", "afraid"]


static func actor_collision_size() -> Vector2:
	var side = float(TILE_SIZE) * ACTOR_COLLISION_TILE_RATIO
	return Vector2(side, side)


static func actor_collision_position() -> Vector2:
	var size = actor_collision_size()
	return Vector2(0.0, ACTOR_COLLISION_BOTTOM_Y - size.y * 0.5)


static func actor_collision_rect_at(world_position: Vector2) -> Rect2:
	var size = actor_collision_size()
	return Rect2(world_position + actor_collision_position() - size * 0.5, size)


static func llm_base_url() -> String:
	var value = OS.get_environment("WITHYOU_LLM_API_BASE")
	return DEFAULT_LLM_BASE_URL if value.is_empty() else value.trim_suffix("/")


static func llm_api_key() -> String:
	return OS.get_environment("WITHYOU_LLM_API_KEY")


static func llm_model() -> String:
	var value = OS.get_environment("WITHYOU_LLM_MODEL")
	return DEFAULT_LLM_MODEL if value.is_empty() else value


static func llm_compress_model() -> String:
	var value = OS.get_environment("WITHYOU_LLM_COMPRESS_MODEL")
	return DEFAULT_LLM_COMPRESS_MODEL if value.is_empty() else value


static func normalize_build_kind(value: String) -> String:
	var lower = value.strip_edges().to_lower()
	match lower:
		"wood_floor", "wooden_floor", "floor", "wood", "木地板", "木板", "地板":
			return "wood_floor"
		"stone_floor", "stone", "石地板", "石板":
			return "stone_floor"
		"wood_wall", "wall", "wooden_wall", "木墙", "墙":
			return "wood_wall"
		_:
			return lower


static func build_cost(kind: String) -> Dictionary:
	var normalized = normalize_build_kind(kind)
	var cost = BUILD_COSTS.get(normalized, {})
	return cost.duplicate(true) if typeof(cost) == TYPE_DICTIONARY else {}


static func build_refund(kind: String) -> Dictionary:
	var normalized = normalize_build_kind(kind)
	var refund = BUILD_REFUNDS.get(normalized, {})
	return refund.duplicate(true) if typeof(refund) == TYPE_DICTIONARY else {}


static func can_build_on_base(tile_kind: String, base_kind: String) -> bool:
	var normalized_tile = normalize_build_kind(tile_kind)
	var normalized_base = normalize_build_kind(base_kind)
	if normalized_base == "water":
		return WATER_BUILDABLE_TILE_KINDS.has(normalized_tile)
	if normalized_base == "city_border":
		return false
	return not is_blocking_tile_kind(normalized_base)


static func is_destroyable_terrain_kind(kind: String) -> bool:
	return TERRAIN_DESTROY_DROPS.has(normalize_build_kind(kind))


static func terrain_destroy_drop(kind: String) -> Dictionary:
	var normalized = normalize_build_kind(kind)
	var drop = TERRAIN_DESTROY_DROPS.get(normalized, {})
	return drop.duplicate(true) if typeof(drop) == TYPE_DICTIONARY else {}


static func terrain_destroy_replacement(kind: String) -> String:
	var normalized = normalize_build_kind(kind)
	return str(TERRAIN_DESTROY_REPLACEMENTS.get(normalized, "plain"))


static func is_blocking_tile_kind(kind: String) -> bool:
	var lower = kind.strip_edges().to_lower()
	return BLOCKING_TILE_KINDS.has(lower) or BLOCKING_TILE_KINDS.has(normalize_build_kind(lower))


static func item_label(item_id: String) -> String:
	match item_id:
		"wood":
			return "木材"
		"stone":
			return "石材"
		_:
			return item_id


static func has_skill(skills, skill_id: String) -> bool:
	if typeof(skills) != TYPE_ARRAY:
		return false
	var wanted = skill_id.strip_edges().to_lower()
	for skill in skills:
		if typeof(skill) == TYPE_DICTIONARY and str(skill.get("id", "")).strip_edges().to_lower() == wanted:
			return true
	return false


static func actor_can_swim(skills) -> bool:
	return has_skill(skills, "swimming")


static func actor_build_radius(base_radius: int, skills) -> int:
	var radius = max(0, base_radius)
	if has_skill(skills, "building"):
		radius += 1
	return radius


static func actor_speed_scale(attributes: Dictionary) -> float:
	var energy = float(attributes.get("energy", 100.0))
	var hunger = float(attributes.get("hunger", 0.0))
	var scale = 0.55 + 0.45 * clamp(energy / 100.0, 0.0, 1.2)
	if hunger >= 85.0:
		scale *= 0.7
	return clampf(scale, 0.4, 1.15)


static func tick_vital_attributes(attributes: Dictionary, moving: bool, delta: float, game_minutes_delta: float) -> Dictionary:
	var next = attributes.duplicate(true)
	var hunger = clampf(float(next.get("hunger", 0.0)) + game_minutes_delta * HUNGER_PER_GAME_MINUTE, 0.0, ATTRIBUTE_MAX)
	var energy = float(next.get("energy", 100.0))
	if moving:
		energy -= ENERGY_MOVE_PER_SECOND * delta
	else:
		var regen = ENERGY_REGEN_PER_SECOND * delta
		if hunger >= 80.0:
			regen *= 0.25
		energy += regen
	next["hunger"] = hunger
	next["energy"] = clampf(energy, 0.0, ATTRIBUTE_MAX)
	return next


static func compact_action(action: Dictionary) -> Dictionary:
	if action.is_empty():
		return {}
	var result = action.duplicate(true)
	if result.has("path") and typeof(result["path"]) == TYPE_ARRAY:
		result["path_length"] = result["path"].size()
		result.erase("path")
	return result


static func extra_forage_drop(skills, removed_kind: String) -> Dictionary:
	if has_skill(skills, "foraging") and normalize_build_kind(removed_kind) == "tree":
		return {"wood": 1}
	return {}


static func is_fullscreen_mode(value) -> bool:
	var text = str(value).strip_edges().to_lower()
	return text in ["fullscreen", "full_screen", "full", "exclusive", "1", "true"]


static func window_mode_name(fullscreen: bool) -> String:
	return WINDOW_MODE_FULLSCREEN if fullscreen else WINDOW_MODE_WINDOWED


static func clamp_windowed_size(desired: Vector2i) -> Vector2i:
	var max_size = max_windowed_client_size()
	var requested = desired
	if requested.x <= 0 or requested.y <= 0:
		requested = DEFAULT_WINDOWED_RESOLUTION
	if requested.x <= max_size.x and requested.y <= max_size.y:
		return requested

	var fitted = Vector2i.ZERO
	for option in RESOLUTION_OPTIONS:
		if option.x <= max_size.x and option.y <= max_size.y:
			fitted = option
	if fitted != Vector2i.ZERO:
		return fitted
	return _fit_size_into(requested, max_size)


static func max_windowed_client_size() -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return Vector2i(3840, 2160)

	var screen = DisplayServer.window_get_current_screen()
	var usable = DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		usable = Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen))

	var deco = window_decoration_size()
	return Vector2i(max(1, usable.size.x - deco.x), max(1, usable.size.y - deco.y))


static func window_decoration_size() -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return Vector2i.ZERO

	var outer = DisplayServer.window_get_size_with_decorations()
	var inner = DisplayServer.window_get_size()
	var deco = outer - inner
	if deco.x < 0 or deco.y < 0 or (deco.x == 0 and deco.y == 0):
		return WINDOW_DECORATION_FALLBACK
	return deco


static func centered_window_position(client_size: Vector2i) -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return Vector2i.ZERO

	var screen = DisplayServer.window_get_current_screen()
	var usable = DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		usable = Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen))

	var total = client_size + window_decoration_size()
	var pos = usable.position + (usable.size - total) / 2
	var max_pos = usable.position + usable.size - total
	pos.x = clampi(pos.x, usable.position.x, max(usable.position.x, max_pos.x))
	pos.y = clampi(pos.y, usable.position.y, max(usable.position.y, max_pos.y))
	return pos


static func _fit_size_into(desired: Vector2i, max_size: Vector2i) -> Vector2i:
	var width = max(1, desired.x)
	var height = max(1, desired.y)
	var scale = min(float(max_size.x) / float(width), float(max_size.y) / float(height))
	scale = min(scale, 1.0)
	return Vector2i(
		max(1, int(floor(float(width) * scale))),
		max(1, int(floor(float(height) * scale)))
	)


static func tile_label(kind: String) -> String:
	match normalize_build_kind(kind):
		"wood_floor":
			return "木地板"
		"stone_floor":
			return "石地板"
		"wood_wall":
			return "木墙"
		"city":
			return "城区地面"
		"city_border":
			return "城区边界"
		"grass":
			return "草地"
		"plain":
			return "平地"
		"water":
			return "水"
		"tree":
			return "树"
		"stone_hill":
			return "石头小山"
		_:
			return kind
