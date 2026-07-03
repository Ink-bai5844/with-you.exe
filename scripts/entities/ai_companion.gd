class_name AICompanion
extends CharacterBody2D

signal mood_changed(mood)
signal follow_changed(enabled)
signal action_event(event)

const GameConfig = preload("res://scripts/config/game_config.gd")
const CharacterProfiles = preload("res://scripts/profiles/character_profiles.gd")
const PixelActorViewScene = preload("res://scripts/visual/pixel_actor_view.gd")

const COLLISION_LAYER_AI = 2
const COLLISION_MASK_WORLD = 4
const FOLLOW_LEASH_DISTANCE = 72.0
const FOLLOW_TARGET_TOLERANCE = 8.0
const FOLLOW_MIN_PLAYER_DISTANCE = 24.0
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

var speed = GameConfig.AI_SPEED
var profile = CharacterProfiles.ai_default()
var attributes = profile.get("attributes", {}).duplicate(true)
var skills = profile.get("skills", []).duplicate(true)
var mood = "calm"
var facing = "down"
var follow_enabled = false

var follow_target: Node2D
var world
var action_queue: Array = []
var current_action = {}
var _view


func _action_type(action: Dictionary) -> String:
	return str(action.get("type", "idle"))


func _is_passive_action(action: Dictionary) -> bool:
	var type = _action_type(action)
	return type == "idle" or type == "follow_player"


func _ready() -> void:
	collision_layer = COLLISION_LAYER_AI
	collision_mask = COLLISION_MASK_WORLD

	_view = PixelActorViewScene.new()
	_view.set_ai_skin()
	_view.set_mood(mood)
	add_child(_view)
	_apply_profile_visual()

	var shape = RectangleShape2D.new()
	shape.size = Vector2(10, 12)
	var collision = CollisionShape2D.new()
	collision.shape = shape
	add_child(collision)


func set_follow_target(target: Node2D) -> void:
	follow_target = target


func set_world(world_node) -> void:
	world = world_node


func apply_profile(new_profile: Dictionary) -> void:
	profile = new_profile.duplicate(true)
	if str(profile.get("id", "")) == "default_mobai":
		profile["sprite_sheet"] = DEFAULT_MOBAI_SPRITE_SHEET.duplicate(true)
	attributes = profile.get("attributes", {}).duplicate(true)
	skills = profile.get("skills", []).duplicate(true)
	_apply_profile_visual()


func apply_save_data(data: Dictionary) -> void:
	if typeof(data.get("profile", null)) == TYPE_DICTIONARY:
		apply_profile(data["profile"])
	attributes = data.get("attributes", attributes).duplicate(true)
	skills = data.get("skills", skills).duplicate(true)
	var position = data.get("position", [32.0, 24.0])
	if typeof(position) == TYPE_ARRAY and position.size() >= 2:
		global_position = Vector2(float(position[0]), float(position[1]))
	facing = str(data.get("facing", "down"))
	follow_enabled = bool(data.get("follow_enabled", false))
	current_action = data.get("current_action", {}).duplicate(true)
	action_queue = data.get("action_queue", []).duplicate(true)
	set_mood(str(data.get("mood", "calm")))
	if _view != null:
		_view.set_direction(facing)
		_apply_profile_visual()


func get_save_data() -> Dictionary:
	return {
		"profile": profile.duplicate(true),
		"profile_id": profile.get("id", "companion_ai"),
		"name": profile.get("name", "AI"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"mood": mood,
		"facing": facing,
		"follow_enabled": follow_enabled,
		"current_action": current_action.duplicate(true),
		"action_queue": action_queue.duplicate(true),
	}


func set_follow_enabled(value: bool) -> void:
	if follow_enabled == value:
		return
	follow_enabled = value
	if not follow_enabled and _action_type(current_action) == "follow_player":
		current_action = {}
	follow_changed.emit(follow_enabled)


func set_mood(value: String) -> void:
	if not GameConfig.MOODS.has(value):
		value = "calm"
	mood = value
	if _view != null:
		_view.set_mood(mood)
	mood_changed.emit(mood)


func _apply_profile_visual() -> void:
	if _view == null:
		return
	var sprite_sheet = _sprite_sheet_from_profile()
	if not sprite_sheet.is_empty():
		_view.set_sprite_sheet(sprite_sheet)
	else:
		_view.set_sprite_sheet({})


func _sprite_sheet_from_profile() -> Dictionary:
	if typeof(profile.get("sprite_sheet", null)) == TYPE_DICTIONARY:
		return profile["sprite_sheet"].duplicate(true)
	if typeof(profile.get("visual", null)) == TYPE_DICTIONARY:
		var visual: Dictionary = profile["visual"]
		if typeof(visual.get("sprite_sheet", null)) == TYPE_DICTIONARY:
			return visual["sprite_sheet"].duplicate(true)
	if str(profile.get("id", "")) == "default_mobai":
		return DEFAULT_MOBAI_SPRITE_SHEET.duplicate(true)
	return {}


func _set_view_moving(value: bool) -> void:
	if _view != null:
		_view.set_moving(value)


func enqueue_action(action: Dictionary) -> void:
	var normalized = _normalize_action(action)
	if normalized.is_empty():
		return

	var type = _action_type(normalized)
	if type == "idle":
		clear_actions()
		current_action = normalized
		return

	if _is_passive_action(current_action):
		current_action = {}
	action_queue.append(normalized)


func clear_actions() -> void:
	action_queue.clear()
	current_action = {}


func _physics_process(_delta: float) -> void:
	var target_position = _resolve_target_position()
	if target_position == null:
		velocity = Vector2.ZERO
		_set_view_moving(false)
		move_and_slide()
		return

	var delta_to_target: Vector2 = target_position - global_position
	if delta_to_target.length() < 5.0:
		velocity = Vector2.ZERO
		_set_view_moving(false)
		_finish_current_action_step()
		move_and_slide()
		return

	velocity = delta_to_target.normalized() * speed
	_update_facing(velocity)
	_set_view_moving(true)
	move_and_slide()


func get_state() -> Dictionary:
	return {
		"profile_id": profile.get("id", "companion_ai"),
		"name": profile.get("name", "悠"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"mood": mood,
		"facing": facing,
		"follow_enabled": follow_enabled,
		"current_action": current_action.duplicate(true),
		"queued_actions": action_queue.size(),
	}


func _resolve_target_position():
	if current_action.is_empty() and not action_queue.is_empty():
		current_action = action_queue.pop_front()

	if not current_action.is_empty():
		var action_type = str(current_action.get("type", "idle"))
		if action_type == "move_to_world":
			var point = current_action.get("world_position", [global_position.x, global_position.y])
			return Vector2(float(point[0]), float(point[1]))
		if action_type == "move_to_tile":
			var tile = current_action.get("tile", [0, 0])
			return Vector2(float(tile[0]) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5, float(tile[1]) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5)
		if action_type == "path_to_tile":
			return _path_action_target_position()
		if action_type == "search_for_tile":
			return _search_action_target_position()
		if action_type == "wander":
			return _wander_action_target_position()
		if action_type == "follow_player":
			var follow_position = _follow_target_position(true)
			if follow_position == null:
				current_action = {}
			return follow_position
		if action_type == "idle":
			return null
		current_action = {}

	return _follow_target_position()


func _normalize_action(action: Dictionary) -> Dictionary:
	var type = str(action.get("type", "idle"))
	if type == "move_to_tile":
		var tile = action.get("tile", [])
		if typeof(tile) != TYPE_ARRAY or tile.size() < 2:
			return {}
		return {
			"type": "move_to_tile",
			"tile": [int(tile[0]), int(tile[1])],
		}
	if type == "move_to_world":
		var world_position = action.get("world_position", [])
		if typeof(world_position) != TYPE_ARRAY or world_position.size() < 2:
			return {}
		return {
			"type": "move_to_world",
			"world_position": [float(world_position[0]), float(world_position[1])],
		}
	if type == "path_to_tile":
		var path_tile = action.get("tile", [])
		if typeof(path_tile) != TYPE_ARRAY or path_tile.size() < 2:
			return {}
		return {
			"type": "path_to_tile",
			"tile": [int(path_tile[0]), int(path_tile[1])],
			"avoid": _string_array(action.get("avoid", [])),
			"path": [],
			"max_nodes": int(action.get("max_nodes", 5000)),
		}
	if type == "search_for_tile" or type == "search_for":
		var target = str(action.get("target", action.get("target_kind", action.get("tile_kind", "")))).strip_edges()
		if target.is_empty():
			return {}
		return {
			"type": "search_for_tile",
			"target": _normalize_tile_kind_name(target),
			"scan_radius": int(clamp(int(action.get("scan_radius", action.get("radius", 10))), 1, 48)),
			"step_tiles": int(clamp(int(action.get("step_tiles", 8)), 1, 24)),
			"steps_remaining": int(clamp(int(action.get("max_steps", action.get("steps", 24))), 1, 200)),
			"avoid": _string_array(action.get("avoid", [])),
			"path": [],
			"status": "searching",
			"found_tile": [],
			"max_nodes": int(action.get("max_nodes", 5000)),
		}
	if type == "wander":
		return {
			"type": "wander",
			"center_tile": _optional_tile(action.get("center_tile", [])),
			"radius": int(clamp(int(action.get("radius", 16)), 1, 80)),
			"step_tiles": int(clamp(int(action.get("step_tiles", 8)), 1, 24)),
			"steps_remaining": int(clamp(int(action.get("steps", 8)), 1, 100)),
			"avoid": _string_array(action.get("avoid", [])),
			"path": [],
			"max_nodes": int(action.get("max_nodes", 5000)),
		}
	if type == "follow_player":
		return {"type": "follow_player"}
	if type == "idle":
		return {"type": "idle"}
	return {}


func _follow_target_position(force = false):
	if (not force and not follow_enabled) or follow_target == null:
		return null
	var desired = _best_follow_position()
	var desired_distance = global_position.distance_to(desired)
	if desired_distance <= FOLLOW_TARGET_TOLERANCE:
		return null
	if force:
		return desired
	if global_position.distance_to(follow_target.global_position) > FOLLOW_LEASH_DISTANCE:
		return desired
	if desired_distance > FOLLOW_LEASH_DISTANCE:
		return desired
	return null


func _best_follow_position() -> Vector2:
	var best_position = follow_target.global_position + Vector2(28, 20)
	var best_score = INF
	for offset in _follow_offsets_for_target():
		var candidate = follow_target.global_position + offset
		if candidate.distance_to(follow_target.global_position) < FOLLOW_MIN_PLAYER_DISTANCE:
			continue
		var score = global_position.distance_to(candidate)
		if world != null and _normalize_tile_kind_name(str(world.get_tile_kind(world.world_to_tile(candidate)))) == "water":
			score += 10000.0
		if score < best_score:
			best_score = score
			best_position = candidate
	return best_position


func _follow_offsets_for_target() -> Array:
	var target_facing = str(follow_target.get("facing"))
	match target_facing:
		"right":
			return [Vector2(-30, 18), Vector2(-30, -18), Vector2(0, 34), Vector2(0, -34), Vector2(34, 18), Vector2(34, -18)]
		"left":
			return [Vector2(30, 18), Vector2(30, -18), Vector2(0, 34), Vector2(0, -34), Vector2(-34, 18), Vector2(-34, -18)]
		"up":
			return [Vector2(24, 30), Vector2(-24, 30), Vector2(34, 0), Vector2(-34, 0), Vector2(24, -30), Vector2(-24, -30)]
		"down":
			return [Vector2(24, -30), Vector2(-24, -30), Vector2(34, 0), Vector2(-34, 0), Vector2(24, 30), Vector2(-24, 30)]
		_:
			return [Vector2(28, 20), Vector2(-28, 20), Vector2(28, -20), Vector2(-28, -20), Vector2(36, 0), Vector2(-36, 0), Vector2(0, 36), Vector2(0, -36)]


func _finish_current_action_step() -> void:
	if current_action.is_empty():
		return

	var action_type = _action_type(current_action)
	if action_type == "path_to_tile":
		_pop_path_step()
		if _path_is_empty():
			_emit_action_event("action_completed", {
				"action_type": action_type,
				"target_tile": current_action.get("tile", []),
			})
			current_action = {}
		return

	if action_type == "search_for_tile":
		_pop_path_step()
		if _path_is_empty() and str(current_action.get("status", "searching")) == "moving_to_found":
			_emit_action_event("action_completed", {
				"action_type": action_type,
				"target": current_action.get("target", ""),
				"found_tile": current_action.get("found_tile", []),
				"status": "arrived_at_found_tile",
			})
			current_action = {}
		return

	if action_type == "wander":
		_pop_path_step()
		if _path_is_empty() and int(current_action.get("steps_remaining", 0)) <= 0:
			_emit_action_event("action_completed", {
				"action_type": action_type,
				"status": "wander_finished",
			})
			current_action = {}
		return

	_emit_action_event("action_completed", {
		"action_type": action_type,
	})
	current_action = {}


func _path_action_target_position():
	if _path_is_empty():
		var target_tile = current_action.get("tile", [])
		current_action["path"] = _build_tile_path(target_tile, current_action.get("avoid", []), int(current_action.get("max_nodes", 5000)))
		if _path_is_empty():
			current_action = {}
			return null
	return _tile_center(_path_front())


func _search_action_target_position():
	if world == null:
		current_action = {}
		return null

	if _path_is_empty():
		var found = _find_nearest_tile_kind(str(current_action.get("target", "")), int(current_action.get("scan_radius", 10)))
		if not found.is_empty():
			current_action["found_tile"] = found
			current_action["status"] = "moving_to_found"
			_emit_action_event("search_target_found", {
				"action_type": "search_for_tile",
				"target": current_action.get("target", ""),
				"found_tile": found,
				"tile_kind": current_action.get("target", ""),
			})
			current_action["path"] = _build_tile_path(found, current_action.get("avoid", []), int(current_action.get("max_nodes", 5000)))
			if _path_is_empty():
				current_action = {}
				return null
			return _tile_center(_path_front())

		var steps_remaining = int(current_action.get("steps_remaining", 0))
		if steps_remaining <= 0:
			_emit_action_event("search_failed", {
				"action_type": "search_for_tile",
				"target": current_action.get("target", ""),
				"scan_radius": current_action.get("scan_radius", 10),
			})
			current_action = {}
			return null
		current_action["steps_remaining"] = steps_remaining - 1
		current_action["status"] = "searching"
		var next_tile = _random_explore_tile(int(current_action.get("step_tiles", 8)), current_action.get("avoid", []))
		current_action["path"] = _build_tile_path(next_tile, current_action.get("avoid", []), int(current_action.get("max_nodes", 5000)))
		if _path_is_empty():
			return _tile_center(next_tile)

	return _tile_center(_path_front())


func _wander_action_target_position():
	if world == null:
		current_action = {}
		return null

	if _path_is_empty():
		var steps_remaining = int(current_action.get("steps_remaining", 0))
		if steps_remaining <= 0:
			current_action = {}
			return null
		current_action["steps_remaining"] = steps_remaining - 1
		var next_tile = _random_wander_tile()
		current_action["path"] = _build_tile_path(next_tile, current_action.get("avoid", []), int(current_action.get("max_nodes", 5000)))
		if _path_is_empty():
			return _tile_center(next_tile)

	return _tile_center(_path_front())


func _build_tile_path(target_tile_value, avoid_value, max_nodes: int) -> Array:
	if world == null:
		return []
	var target_tile = _tile_from_value(target_tile_value)
	var start_tile = world.world_to_tile(global_position)
	if start_tile == target_tile:
		return []

	var avoid = _normalized_tile_kind_array(avoid_value)
	var min_x = min(start_tile.x, target_tile.x) - 12
	var max_x = max(start_tile.x, target_tile.x) + 12
	var min_y = min(start_tile.y, target_tile.y) - 12
	var max_y = max(start_tile.y, target_tile.y) + 12
	var estimated_nodes = (max_x - min_x + 1) * (max_y - min_y + 1)
	if estimated_nodes > max(max_nodes, 64):
		return _straight_tile_path(start_tile, target_tile)

	var queue: Array[Vector2i] = [start_tile]
	var came_from = {}
	var visited = {}
	var head = 0
	visited[start_tile] = true
	var directions = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

	while head < queue.size():
		var current = queue[head]
		head += 1
		if current == target_tile:
			break
		for direction in directions:
			var next_tile = current + direction
			if next_tile.x < min_x or next_tile.x > max_x or next_tile.y < min_y or next_tile.y > max_y:
				continue
			if visited.has(next_tile):
				continue
			if next_tile != target_tile and _tile_is_avoided(next_tile, avoid):
				continue
			visited[next_tile] = true
			came_from[next_tile] = current
			queue.append(next_tile)

	if not visited.has(target_tile):
		return []

	var reversed_path: Array = []
	var step = target_tile
	while step != start_tile:
		reversed_path.append([step.x, step.y])
		step = came_from[step]
	reversed_path.reverse()
	return reversed_path


func _straight_tile_path(start_tile: Vector2i, target_tile: Vector2i) -> Array:
	var path = []
	var current = start_tile
	while current.x != target_tile.x:
		current.x += 1 if target_tile.x > current.x else -1
		path.append([current.x, current.y])
	while current.y != target_tile.y:
		current.y += 1 if target_tile.y > current.y else -1
		path.append([current.x, current.y])
	return path


func _find_nearest_tile_kind(target_kind: String, radius: int) -> Array:
	if world == null:
		return []
	var center = world.world_to_tile(global_position)
	var normalized_target = _normalize_tile_kind_name(target_kind)
	var best_tile = []
	var best_distance = INF
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var tile = Vector2i(x, y)
			var kind = _normalize_tile_kind_name(str(world.get_tile_kind(tile)))
			if kind != normalized_target:
				continue
			var distance = Vector2(tile.x - center.x, tile.y - center.y).length_squared()
			if distance < best_distance:
				best_distance = distance
				best_tile = [tile.x, tile.y]
	return best_tile


func _random_explore_tile(step_tiles: int, avoid_value) -> Array:
	if world == null:
		return [0, 0]
	var avoid = _normalized_tile_kind_array(avoid_value)
	var center = world.world_to_tile(global_position)
	for _attempt in range(16):
		var offset = Vector2i(randi_range(-step_tiles, step_tiles), randi_range(-step_tiles, step_tiles))
		if offset == Vector2i.ZERO:
			offset = Vector2i(step_tiles, 0)
		var candidate = center + offset
		if not _tile_is_avoided(candidate, avoid):
			return [candidate.x, candidate.y]
	return [center.x + step_tiles, center.y]


func _random_wander_tile() -> Array:
	var center = world.world_to_tile(global_position)
	var center_value = current_action.get("center_tile", [])
	if typeof(center_value) == TYPE_ARRAY and center_value.size() >= 2:
		center = Vector2i(int(center_value[0]), int(center_value[1]))
	else:
		current_action["center_tile"] = [center.x, center.y]
	var radius = int(current_action.get("radius", 16))
	var step_tiles = int(current_action.get("step_tiles", 8))
	var avoid = _normalized_tile_kind_array(current_action.get("avoid", []))
	for _attempt in range(20):
		var current_tile = world.world_to_tile(global_position)
		var offset = Vector2i(randi_range(-step_tiles, step_tiles), randi_range(-step_tiles, step_tiles))
		var candidate = current_tile + offset
		if abs(candidate.x - center.x) > radius or abs(candidate.y - center.y) > radius:
			continue
		if not _tile_is_avoided(candidate, avoid):
			return [candidate.x, candidate.y]
	return [center.x, center.y]


func _tile_is_avoided(tile: Vector2i, avoid: Array) -> bool:
	if world == null:
		return false
	var kind = _normalize_tile_kind_name(str(world.get_tile_kind(tile)))
	return avoid.has(kind)


func _path_is_empty() -> bool:
	return typeof(current_action.get("path", [])) != TYPE_ARRAY or current_action.get("path", []).is_empty()


func _path_front() -> Array:
	var path = current_action.get("path", [])
	if typeof(path) != TYPE_ARRAY or path.is_empty():
		return []
	return path[0]


func _pop_path_step() -> void:
	var path = current_action.get("path", [])
	if typeof(path) == TYPE_ARRAY and not path.is_empty():
		path.pop_front()
		current_action["path"] = path


func _tile_center(tile_value) -> Vector2:
	var tile = _tile_from_value(tile_value)
	return Vector2(float(tile.x) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5, float(tile.y) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5)


func _tile_from_value(value) -> Vector2i:
	if typeof(value) == TYPE_VECTOR2I:
		return value
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return world.world_to_tile(global_position) if world != null else Vector2i.ZERO


func _optional_tile(value) -> Array:
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return [int(value[0]), int(value[1])]
	return []


func _string_array(value) -> Array:
	var result = []
	if typeof(value) == TYPE_STRING:
		result.append(_normalize_tile_kind_name(value))
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			result.append(_normalize_tile_kind_name(str(item)))
	return result


func _normalized_tile_kind_array(value) -> Array:
	return _string_array(value)


func _normalize_tile_kind_name(value: String) -> String:
	var lower = value.strip_edges().to_lower()
	match lower:
		"river", "river_water", "water", "水", "河", "河流":
			return "water"
		"grass", "grassland", "草", "草地":
			return "grass"
		"plain", "plains", "平地":
			return "plain"
		"city", "city_floor", "城区", "城市":
			return "city"
		"city_border", "border", "边界", "城区边界":
			return "city_border"
		_:
			return lower


func _emit_action_event(event_type: String, payload: Dictionary) -> void:
	var tile = world.world_to_tile(global_position) if world != null else Vector2i.ZERO
	var event = payload.duplicate(true)
	event["event_type"] = event_type
	event["ai_tile"] = [tile.x, tile.y]
	event["ai_position"] = [global_position.x, global_position.y]
	event["current_action"] = current_action.duplicate(true)
	action_event.emit(event)


func _update_facing(move_vector: Vector2) -> void:
	if abs(move_vector.x) > abs(move_vector.y):
		facing = "right" if move_vector.x > 0.0 else "left"
	else:
		facing = "down" if move_vector.y > 0.0 else "up"
	if _view != null:
		_view.set_direction(facing)
