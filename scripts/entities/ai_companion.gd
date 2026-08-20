class_name AICompanion
extends CharacterBody2D

signal mood_changed(mood)
signal follow_changed(enabled)
signal action_event(event)
signal inventory_changed(snapshot)

const GameConfig = preload("res://scripts/config/game_config.gd")
const CharacterProfiles = preload("res://scripts/profiles/character_profiles.gd")
const PixelActorViewScene = preload("res://scripts/visual/pixel_actor_view.gd")

const COLLISION_LAYER_AI = 2
const COLLISION_MASK_WORLD = 4
const FOLLOW_LEASH_DISTANCE = 72.0
const FOLLOW_TARGET_TOLERANCE = 8.0
const FOLLOW_MIN_PLAYER_DISTANCE = 24.0
const DEFAULT_MOBAI_SPRITE_SHEET = GameConfig.DEFAULT_MOBAI_SPRITE_SHEET

var speed = GameConfig.AI_SPEED
var profile = CharacterProfiles.ai_default()
var attributes = profile.get("attributes", {}).duplicate(true)
var skills = profile.get("skills", []).duplicate(true)
var inventory = GameConfig.DEFAULT_AI_INVENTORY.duplicate(true)
var mood = "calm"
var facing = "down"
var follow_enabled = false

var follow_target: Node2D
var world
var action_queue: Array = []
var current_action = {}
var _view
var _follow_stuck_seconds = 0.0
var _follow_last_position = Vector2.ZERO
var _follow_has_last_position = false
var _follow_teleport_cooldown = 0.0
var _movement_stuck_seconds = 0.0
var _movement_last_position = Vector2.ZERO
var _movement_has_last_position = false
var _movement_teleport_cooldown = 0.0


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
	shape.size = GameConfig.actor_collision_size()
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.position = GameConfig.actor_collision_position()
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
	inventory = _inventory_from_value(profile.get("inventory", GameConfig.DEFAULT_AI_INVENTORY), GameConfig.DEFAULT_AI_INVENTORY)
	inventory_changed.emit(inventory.duplicate(true))
	_apply_profile_visual()


func apply_save_data(data: Dictionary) -> void:
	if typeof(data.get("profile", null)) == TYPE_DICTIONARY:
		apply_profile(data["profile"])
	attributes = data.get("attributes", attributes).duplicate(true)
	skills = data.get("skills", skills).duplicate(true)
	inventory = _inventory_from_value(data.get("inventory", inventory), GameConfig.DEFAULT_AI_INVENTORY)
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
	_reset_follow_recovery_state()
	_reset_movement_recovery_state()
	inventory_changed.emit(inventory.duplicate(true))


func get_save_data() -> Dictionary:
	return {
		"profile": profile.duplicate(true),
		"profile_id": profile.get("id", "companion_ai"),
		"name": profile.get("name", "AI"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"inventory": inventory.duplicate(true),
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
	_reset_follow_recovery_state()
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
	var interrupt_current = _action_requests_interrupt(action)
	if str(action.get("type", "")) == "sequence":
		var actions = action.get("actions", [])
		if typeof(actions) != TYPE_ARRAY:
			return
		var normalized_actions = []
		for item in actions:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var normalized_item = _normalize_action(item)
			if not normalized_item.is_empty():
				if item.has("task_id"):
					normalized_item["task_id"] = str(item.get("task_id", ""))
				normalized_actions.append(normalized_item)
		if normalized_actions.is_empty():
			return
		if interrupt_current:
			_interrupt_actions("replaced_by_sequence")
		if _is_passive_action(current_action):
			current_action = {}
		for normalized_item in normalized_actions:
			action_queue.append(normalized_item)
		return

	var normalized = _normalize_action(action)
	if normalized.is_empty():
		return
	if action.has("task_id"):
		normalized["task_id"] = str(action.get("task_id", ""))

	var type = _action_type(normalized)
	if type == "interrupt_action":
		_interrupt_actions(str(normalized.get("reason", "explicit_interrupt")))
		return

	if interrupt_current:
		_interrupt_actions("replaced_by_new_action")

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
	velocity = Vector2.ZERO
	_set_view_moving(false)
	_reset_movement_recovery_state()


func _interrupt_actions(reason: String) -> void:
	var interrupted_type = _action_type(current_action)
	var queued_count = action_queue.size()
	if current_action.is_empty() and queued_count <= 0:
		clear_actions()
		return

	_emit_action_event("action_interrupted", {
		"action_type": interrupted_type,
		"status": "interrupted",
		"reason": reason,
		"queued_actions_cleared": queued_count,
	})
	clear_actions()


func _physics_process(delta: float) -> void:
	speed = GameConfig.AI_SPEED * GameConfig.actor_speed_scale(attributes)
	var target_position = _resolve_target_position()
	if target_position == null:
		velocity = Vector2.ZERO
		_set_view_moving(false)
		_update_follow_recovery(delta, false, false)
		_update_movement_recovery(delta, false, false, null)
		_tick_vitals(delta)
		return

	var delta_to_target: Vector2 = target_position - global_position
	if delta_to_target.length() < 5.0:
		velocity = Vector2.ZERO
		_set_view_moving(false)
		_finish_current_action_step()
		_update_follow_recovery(delta, false, false)
		_update_movement_recovery(delta, false, false, target_position)
		_tick_vitals(delta)
		return

	velocity = delta_to_target.normalized() * speed
	_update_facing(velocity)
	var old_position = global_position
	var was_blocked = _move_with_world_collision(delta)
	var moved = global_position.distance_to(old_position) > 0.01
	_set_view_moving(moved)
	if was_blocked and not moved and typeof(current_action.get("path", null)) == TYPE_ARRAY:
		current_action["path"] = []
	_update_follow_recovery(delta, was_blocked, true)
	_update_movement_recovery(delta, was_blocked, true, target_position)
	_tick_vitals(delta)


func get_state() -> Dictionary:
	return {
		"profile_id": profile.get("id", "companion_ai"),
		"name": profile.get("name", "悠"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"inventory": inventory.duplicate(true),
		"mood": mood,
		"facing": facing,
		"follow_enabled": follow_enabled,
		"can_swim": GameConfig.actor_can_swim(skills),
		"current_action": GameConfig.compact_action(current_action),
		"queued_actions": action_queue.size(),
	}


func has_items(cost: Dictionary) -> bool:
	for item_id in cost.keys():
		if int(inventory.get(item_id, 0)) < int(cost[item_id]):
			return false
	return true


func consume_items(cost: Dictionary) -> bool:
	if not has_items(cost):
		return false
	for item_id in cost.keys():
		var remaining = int(inventory.get(item_id, 0)) - int(cost[item_id])
		if remaining <= 0:
			inventory.erase(item_id)
		else:
			inventory[item_id] = remaining
	inventory_changed.emit(inventory.duplicate(true))
	return true


func add_items(items: Dictionary) -> void:
	for item_id in items.keys():
		var amount = int(items[item_id])
		if amount <= 0:
			continue
		inventory[item_id] = int(inventory.get(item_id, 0)) + amount
	inventory_changed.emit(inventory.duplicate(true))


func _resolve_target_position():
	if current_action.is_empty() and not action_queue.is_empty():
		current_action = action_queue.pop_front()
		_reset_movement_recovery_state()

	if not current_action.is_empty():
		var action_type = str(current_action.get("type", "idle"))
		if action_type == "move_to_world":
			var point = current_action.get("world_position", [global_position.x, global_position.y])
			return Vector2(float(point[0]), float(point[1]))
		if action_type == "move_to_tile":
			var tile = current_action.get("tile", [0, 0])
			return _movement_target_position(tile)
		if action_type == "path_to_tile":
			return _path_action_target_position()
		if action_type == "search_for_tile":
			return _search_action_target_position()
		if action_type == "wander":
			return _wander_action_target_position()
		if action_type == "gather_resource":
			return _gather_resource_target_position()
		if action_type == "build_tile" or action_type == "destroy_tile":
			return _tile_interaction_target_position()
		if action_type == "give_item":
			return _give_item_target_position()
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
	if type in ["interrupt_action", "interrupt", "cancel_action", "cancel_current_action", "stop_action", "stop", "clear_actions"]:
		return {
			"type": "interrupt_action",
			"reason": str(action.get("reason", type)),
		}
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
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
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
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
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
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		}
	if type == "gather_resource" or type == "gather" or type == "collect_resource" or type == "collect":
		var resource = _normalize_resource_name(str(action.get("resource", action.get("item", action.get("target_item", "wood")))))
		var target_kinds = _resource_source_kinds(resource, action.get("target", action.get("tile_kind", action.get("target_kind", ""))))
		if target_kinds.is_empty():
			return {}
		return {
			"type": "gather_resource",
			"resource": resource,
			"target_kinds": target_kinds,
			"amount": int(clamp(int(action.get("amount", 1)), 1, 999)),
			"gathered": 0,
			"scan_radius": int(clamp(int(action.get("scan_radius", action.get("radius", 10))), 1, 48)),
			"step_tiles": int(clamp(int(action.get("step_tiles", 8)), 1, 24)),
			"steps_remaining": int(clamp(int(action.get("max_steps", action.get("steps", 24))), 1, 200)),
			"path": [],
			"status": "searching",
			"found_tile": [],
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		}
	if type == "build_tile":
		var build_tile = action.get("tile", [])
		if typeof(build_tile) != TYPE_ARRAY or build_tile.size() < 2:
			return {}
		var tile_kind = GameConfig.normalize_build_kind(str(action.get("tile_kind", action.get("kind", "wood_floor"))))
		if not GameConfig.BUILDABLE_TILE_KINDS.has(tile_kind):
			return {}
		return {
			"type": "build_tile",
			"tile": [int(build_tile[0]), int(build_tile[1])],
			"tile_kind": tile_kind,
			"path": [],
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			"batch_id": str(action.get("batch_id", "")),
			"batch_index": int(action.get("batch_index", 1)),
			"batch_count": int(action.get("batch_count", 1)),
		}
	if type == "destroy_tile" or type == "break_tile":
		var destroy_tile = action.get("tile", [])
		if typeof(destroy_tile) != TYPE_ARRAY or destroy_tile.size() < 2:
			return {}
		return {
			"type": "destroy_tile",
			"tile": [int(destroy_tile[0]), int(destroy_tile[1])],
			"path": [],
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			"batch_id": str(action.get("batch_id", "")),
			"batch_index": int(action.get("batch_index", 1)),
			"batch_count": int(action.get("batch_count", 1)),
		}
	if type == "give_item" or type == "give" or type == "transfer_item":
		var item_id = _normalize_resource_name(str(action.get("item_id", action.get("item", action.get("resource", "")))))
		if item_id.is_empty():
			return {}
		return {
			"type": "give_item",
			"item_id": item_id,
			"amount": int(clamp(int(action.get("amount", 1)), 1, 999)),
			"recipient": str(action.get("recipient", "player")),
		}
	if type == "follow_player":
		return {"type": "follow_player"}
	if type == "idle":
		return {"type": "idle"}
	return {}


func _action_requests_interrupt(action: Dictionary) -> bool:
	for key in ["interrupt_current", "interrupt", "replace_current"]:
		if not action.has(key):
			continue
		var value = action[key]
		if typeof(value) == TYPE_BOOL:
			return value
		if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
			return int(value) != 0
		var text = str(value).strip_edges().to_lower()
		if text in ["true", "yes", "1", "on"]:
			return true
	var queue_mode = str(action.get("queue_mode", "")).strip_edges().to_lower()
	return queue_mode in ["replace", "interrupt", "immediate", "now"]


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
		if world != null:
			var candidate_tile = world.world_to_tile(candidate)
			var kind = _normalize_tile_kind_name(str(world.get_tile_kind(candidate_tile)))
			if kind == "water" or _tile_is_blocking(candidate_tile) or _actor_position_blocked(candidate):
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


func _update_follow_recovery(delta: float, was_blocked: bool, had_move_target: bool) -> void:
	if _follow_teleport_cooldown > 0.0:
		_follow_teleport_cooldown = max(0.0, _follow_teleport_cooldown - delta)

	if not _wants_follow_recovery():
		_reset_follow_recovery_state()
		return

	if follow_target == null:
		_reset_follow_recovery_state()
		return

	if global_position.distance_to(follow_target.global_position) >= GameConfig.AI_FOLLOW_TELEPORT_DISTANCE:
		if _try_follow_recovery_teleport():
			return

	var moved = INF
	if _follow_has_last_position:
		moved = global_position.distance_to(_follow_last_position)
	_follow_last_position = global_position
	_follow_has_last_position = true

	if not had_move_target:
		_follow_stuck_seconds = 0.0
		return

	var min_expected_movement = GameConfig.AI_FOLLOW_STUCK_MIN_SPEED * delta
	if was_blocked or moved <= min_expected_movement:
		_follow_stuck_seconds += delta
	else:
		_follow_stuck_seconds = max(0.0, _follow_stuck_seconds - delta * 2.0)

	if _follow_stuck_seconds >= GameConfig.AI_FOLLOW_STUCK_SECONDS:
		_try_follow_recovery_teleport()


func _wants_follow_recovery() -> bool:
	if follow_target == null:
		return false
	var type = _action_type(current_action)
	if type == "follow_player":
		return true
	return follow_enabled and (current_action.is_empty() or _is_passive_action(current_action))


func _try_follow_recovery_teleport() -> bool:
	if _follow_teleport_cooldown > 0.0:
		return false
	var destination = _find_follow_teleport_position()
	if destination == null:
		_follow_teleport_cooldown = 0.5
		return false

	global_position = destination
	velocity = Vector2.ZERO
	if typeof(current_action.get("path", null)) == TYPE_ARRAY:
		current_action["path"] = []
	_set_view_moving(false)
	if follow_target != null and global_position != follow_target.global_position:
		_update_facing(follow_target.global_position - global_position)
	_reset_follow_recovery_state()
	_follow_teleport_cooldown = GameConfig.AI_FOLLOW_TELEPORT_COOLDOWN_SECONDS
	return true


func _find_follow_teleport_position():
	if world == null or follow_target == null:
		return null
	var player_tile = world.world_to_tile(follow_target.global_position)
	var best_tile = Vector2i.ZERO
	var best_score = INF
	var has_best = false
	var max_radius = max(1, GameConfig.AI_FOLLOW_TELEPORT_SEARCH_RADIUS)

	for radius in range(1, max_radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if max(abs(x), abs(y)) != radius:
					continue
				var candidate = player_tile + Vector2i(x, y)
				if not _tile_is_legal_follow_teleport(candidate, player_tile):
					continue
				var candidate_position = _tile_center([candidate.x, candidate.y])
				var score = Vector2(float(x), float(y)).length_squared() * 1000.0 + candidate_position.distance_squared_to(global_position) * 0.001
				if abs(x) + abs(y) == 1:
					score -= 100.0
				if not has_best or score < best_score:
					best_score = score
					best_tile = candidate
					has_best = true
		if has_best:
			break

	if not has_best:
		return null
	return _tile_center([best_tile.x, best_tile.y])


func _tile_is_legal_follow_teleport(tile: Vector2i, player_tile: Vector2i) -> bool:
	if tile == player_tile:
		return false
	if _tile_is_blocking(tile):
		return false
	if _actor_position_blocked(_tile_center([tile.x, tile.y])):
		return false
	var kind = _normalize_tile_kind_name(str(world.get_tile_kind(tile)))
	return kind != "water"


func _reset_follow_recovery_state() -> void:
	_follow_stuck_seconds = 0.0
	_follow_last_position = global_position
	_follow_has_last_position = false


func _update_movement_recovery(delta: float, was_blocked: bool, had_move_target: bool, target_position) -> void:
	if _movement_teleport_cooldown > 0.0:
		_movement_teleport_cooldown = max(0.0, _movement_teleport_cooldown - delta)

	if _wants_follow_recovery() or not _wants_general_movement_recovery(had_move_target):
		_reset_movement_recovery_state()
		return

	var moved = INF
	if _movement_has_last_position:
		moved = global_position.distance_to(_movement_last_position)
	_movement_last_position = global_position
	_movement_has_last_position = true

	var min_expected_movement = GameConfig.AI_MOVE_STUCK_MIN_SPEED * delta
	if was_blocked or moved <= min_expected_movement:
		_movement_stuck_seconds += delta
	else:
		_movement_stuck_seconds = max(0.0, _movement_stuck_seconds - delta * 2.0)

	if _movement_stuck_seconds >= GameConfig.AI_MOVE_STUCK_SECONDS:
		_try_movement_recovery_teleport(target_position)


func _wants_general_movement_recovery(had_move_target: bool) -> bool:
	if not had_move_target or current_action.is_empty():
		return false
	var type = _action_type(current_action)
	return type in ["move_to_world", "move_to_tile", "path_to_tile", "search_for_tile", "wander", "gather_resource", "build_tile", "destroy_tile", "give_item"]


func _try_movement_recovery_teleport(target_position) -> bool:
	if _movement_teleport_cooldown > 0.0:
		return false
	var origin_tile = world.world_to_tile(global_position) if world != null else Vector2i.ZERO
	var destination = _find_nearest_movement_teleport_position(target_position)
	if destination == null:
		_movement_teleport_cooldown = 0.5
		return false

	global_position = destination
	velocity = Vector2.ZERO
	if typeof(current_action.get("path", null)) == TYPE_ARRAY:
		current_action["path"] = []
	_set_view_moving(false)
	if target_position is Vector2 and global_position != target_position:
		_update_facing(target_position - global_position)
	_reset_movement_recovery_state()
	_movement_teleport_cooldown = GameConfig.AI_MOVE_TELEPORT_COOLDOWN_SECONDS
	var destination_tile = world.world_to_tile(global_position) if world != null else Vector2i.ZERO
	_emit_action_event("movement_unstuck_teleport", {
		"action_type": _action_type(current_action),
		"status": "teleported",
		"reason": "movement_stuck",
		"from_tile": [origin_tile.x, origin_tile.y],
		"to_tile": [destination_tile.x, destination_tile.y],
	})
	return true


func _find_nearest_movement_teleport_position(target_position):
	if world == null:
		return null
	var origin_tile = world.world_to_tile(global_position)
	var best_tile = Vector2i.ZERO
	var best_score = INF
	var has_best = false
	var max_radius = max(1, GameConfig.AI_MOVE_TELEPORT_SEARCH_RADIUS)

	for radius in range(1, max_radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if max(abs(x), abs(y)) != radius:
					continue
				var candidate = origin_tile + Vector2i(x, y)
				if not _tile_is_legal_movement_teleport(candidate, origin_tile):
					continue
				var candidate_position = _tile_center([candidate.x, candidate.y])
				var score = candidate_position.distance_squared_to(global_position)
				if target_position is Vector2:
					score += candidate_position.distance_squared_to(target_position) * 0.01
				if not has_best or score < best_score:
					best_score = score
					best_tile = candidate
					has_best = true
		if has_best:
			break

	if not has_best:
		return null
	return _tile_center([best_tile.x, best_tile.y])


func _tile_is_legal_movement_teleport(tile: Vector2i, origin_tile: Vector2i) -> bool:
	if tile == origin_tile:
		return false
	if _tile_is_blocking(tile):
		return false
	if _actor_position_blocked(_tile_center([tile.x, tile.y])):
		return false
	if follow_target != null and world != null and world.world_to_tile(follow_target.global_position) == tile:
		return false
	return true


func _reset_movement_recovery_state() -> void:
	_movement_stuck_seconds = 0.0
	_movement_last_position = global_position
	_movement_has_last_position = false


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

	if action_type == "gather_resource":
		_finish_gather_action_step()
		return

	if action_type == "build_tile":
		if _finish_tile_interaction_path_step():
			return
		_perform_build_action()
		current_action = {}
		return

	if action_type == "destroy_tile":
		if _finish_tile_interaction_path_step():
			return
		_perform_destroy_action()
		current_action = {}
		return

	if action_type == "give_item":
		_perform_give_item_action()
		current_action = {}
		return

	_emit_action_event("action_completed", {
		"action_type": action_type,
	})
	current_action = {}


func _path_action_target_position():
	if _path_is_empty():
		var target_tile = _tile_from_value(current_action.get("tile", []))
		var destination = _movement_destination_tile(target_tile)
		current_action["path"] = _build_tile_path([destination.x, destination.y], current_action.get("avoid", []), int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
		if _path_is_empty():
			_emit_action_event("path_failed", {
				"action_type": _action_type(current_action),
				"target_tile": [target_tile.x, target_tile.y],
				"status": "failed",
				"reason": "no_path",
			})
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
			var found_destination = _movement_destination_tile(_tile_from_value(found))
			current_action["path"] = _build_tile_path([found_destination.x, found_destination.y], current_action.get("avoid", []), int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
			if _path_is_empty():
				_emit_action_event("path_failed", {
					"action_type": "search_for_tile",
					"target": current_action.get("target", ""),
					"found_tile": found,
					"status": "failed",
					"reason": "no_path_to_found_tile",
				})
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
		current_action["path"] = _build_tile_path(next_tile, current_action.get("avoid", []), int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
		if _path_is_empty():
			if _tile_is_blocking(_tile_from_value(next_tile)):
				return null
			return _tile_center(next_tile)

	return _tile_center(_path_front())


func _wander_action_target_position():
	if world == null:
		current_action = {}
		return null

	if _path_is_empty():
		var steps_remaining = int(current_action.get("steps_remaining", 0))
		if steps_remaining <= 0:
			_emit_action_event("action_completed", {
				"action_type": "wander",
				"status": "wander_finished",
			})
			current_action = {}
			return null
		current_action["steps_remaining"] = steps_remaining - 1
		var next_tile = _random_wander_tile()
		current_action["path"] = _build_tile_path(next_tile, current_action.get("avoid", []), int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
		if _path_is_empty():
			if _tile_is_blocking(_tile_from_value(next_tile)):
				return null
			return _tile_center(next_tile)

	return _tile_center(_path_front())


func _gather_resource_target_position():
	if world == null:
		current_action = {}
		return null

	if str(current_action.get("status", "searching")) == "moving_to_resource":
		var found_tile = _tile_from_value(current_action.get("found_tile", []))
		if _tiles_are_adjacent(world.world_to_tile(global_position), found_tile):
			return global_position
		if _path_is_empty():
			if not _has_walkable_adjacent(found_tile):
				_emit_action_event("gather_failed", {
					"action_type": "gather_resource",
					"target_tile": [found_tile.x, found_tile.y],
					"status": "failed",
					"reason": "no_walkable_adjacent_tile",
				})
				current_action = {}
				return null
			var interaction_tile = _nearest_interaction_tile(found_tile)
			current_action["path"] = _build_tile_path([interaction_tile.x, interaction_tile.y], [], int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
			if _path_is_empty():
				if _tile_is_blocking(interaction_tile):
					_emit_action_event("gather_failed", {
						"action_type": "gather_resource",
						"target_tile": [found_tile.x, found_tile.y],
						"status": "failed",
						"reason": "no_path",
					})
					current_action = {}
					return null
				return _tile_center(interaction_tile)
		return _tile_center(_path_front())

	if _path_is_empty():
		var found = _find_nearest_gather_tile()
		if not found.is_empty():
			var found_tile = _tile_from_value(found)
			if not _has_walkable_adjacent(found_tile):
				_emit_action_event("gather_failed", {
					"action_type": "gather_resource",
					"target_tile": [found_tile.x, found_tile.y],
					"status": "failed",
					"reason": "no_walkable_adjacent_tile",
				})
				current_action = {}
				return null
			current_action["found_tile"] = found
			current_action["status"] = "moving_to_resource"
			var found_destination = _nearest_interaction_tile(found_tile)
			current_action["path"] = _build_tile_path([found_destination.x, found_destination.y], [], int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
			if _path_is_empty():
				return _tile_center(found_destination)
			return _tile_center(_path_front())

		var steps_remaining = int(current_action.get("steps_remaining", 0))
		if steps_remaining <= 0:
			_emit_action_event("gather_failed", {
				"action_type": "gather_resource",
				"resource": str(current_action.get("resource", "")),
				"target": ",".join(_string_array(current_action.get("target_kinds", []))),
				"status": "failed",
				"reason": "resource_not_found",
				"scan_radius": current_action.get("scan_radius", 10),
				"gathered": int(current_action.get("gathered", 0)),
				"amount": int(current_action.get("amount", 1)),
			})
			current_action = {}
			return null
		current_action["steps_remaining"] = steps_remaining - 1
		current_action["status"] = "searching"
		var next_tile = _random_explore_tile(int(current_action.get("step_tiles", 8)), [])
		current_action["path"] = _build_tile_path(next_tile, [], int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
		if _path_is_empty():
			return _tile_center(next_tile)

	return _tile_center(_path_front())


func _tile_interaction_target_position():
	if world == null:
		current_action = {}
		return null
	var target_tile = _tile_from_value(current_action.get("tile", []))
	var current_tile = world.world_to_tile(global_position)
	if _tiles_are_adjacent(current_tile, target_tile):
		return global_position

	if _path_is_empty():
		if not _has_walkable_adjacent(target_tile) and world.world_to_tile(global_position) != target_tile:
			_emit_action_event("path_failed", {
				"action_type": _action_type(current_action),
				"target_tile": [target_tile.x, target_tile.y],
				"status": "failed",
				"reason": "no_walkable_adjacent_tile",
			})
			current_action = {}
			return null
		var interaction_tile = _nearest_interaction_tile(target_tile)
		current_action["path"] = _build_tile_path([interaction_tile.x, interaction_tile.y], [], int(current_action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)))
		if _path_is_empty():
			return _tile_center(interaction_tile)
	return _tile_center(_path_front())


func _build_tile_path(target_tile_value, avoid_value, max_nodes: int) -> Array:
	if world == null:
		return []
	var target_tile = _tile_from_value(target_tile_value)
	var start_tile = world.world_to_tile(global_position)
	if start_tile == target_tile:
		return []

	var avoid = _normalized_tile_kind_array(avoid_value)
	if _tile_is_avoided(target_tile, avoid):
		return []
	var margin = GameConfig.AI_PATH_SEARCH_MARGIN
	var min_x = min(start_tile.x, target_tile.x) - margin
	var max_x = max(start_tile.x, target_tile.x) + margin
	var min_y = min(start_tile.y, target_tile.y) - margin
	var max_y = max(start_tile.y, target_tile.y) + margin
	var estimated_nodes = (max_x - min_x + 1) * (max_y - min_y + 1)
	if estimated_nodes > max(max_nodes, 64):
		return []

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
			if _tile_is_avoided(next_tile, avoid):
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


func _find_nearest_gather_tile() -> Array:
	if world == null:
		return []
	var center = world.world_to_tile(global_position)
	var target_kinds = _string_array(current_action.get("target_kinds", []))
	var radius = int(current_action.get("scan_radius", 10))
	var best_tile = []
	var best_distance = INF
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var tile = Vector2i(x, y)
			var kind = _normalize_tile_kind_name(str(world.get_tile_kind(tile)))
			if not target_kinds.has(kind):
				continue
			if not GameConfig.is_destroyable_terrain_kind(kind):
				continue
			var interaction_tile = _nearest_interaction_tile(tile)
			if not _tiles_are_adjacent(interaction_tile, tile):
				continue
			if _tile_is_blocking(interaction_tile):
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
	return _tile_is_blocking(tile) or avoid.has(kind)


func _move_with_world_collision(delta: float) -> bool:
	if velocity.length_squared() <= 0.0:
		return false
	if world == null:
		move_and_slide()
		return false

	var old_position = global_position
	var movement = velocity * delta
	var step_length = max(1.0, GameConfig.ACTOR_COLLISION_MOVE_STEP)
	var steps = max(1, int(ceil(movement.length() / step_length)))
	var step_movement = movement / float(steps)
	var blocked = false
	for _index in range(steps):
		if _move_collision_step(step_movement):
			blocked = true
	velocity = (global_position - old_position) / max(delta, 0.0001)
	return blocked


func _move_collision_step(step_movement: Vector2) -> bool:
	if step_movement.length_squared() <= 0.0:
		return false
	var blocked = false
	var direct_position = global_position + step_movement
	if not _actor_position_blocked(direct_position):
		global_position = direct_position
		return false

	var first_axis = Vector2(step_movement.x, 0.0)
	var second_axis = Vector2(0.0, step_movement.y)
	if abs(step_movement.y) > abs(step_movement.x):
		first_axis = Vector2(0.0, step_movement.y)
		second_axis = Vector2(step_movement.x, 0.0)

	for axis_movement in [first_axis, second_axis]:
		if axis_movement.length_squared() <= 0.0:
			continue
		var axis_position = global_position + axis_movement
		if _actor_position_blocked(axis_position):
			blocked = true
		else:
			global_position = axis_position
	return blocked


func _actor_position_blocked(actor_position: Vector2) -> bool:
	if world == null:
		return false
	if world.has_method("is_actor_position_blocked"):
		return bool(world.is_actor_position_blocked(actor_position, GameConfig.actor_can_swim(skills)))
	var target_tile = world.world_to_tile(actor_position)
	return _tile_is_blocking(target_tile)


func _tile_is_blocking(tile: Vector2i) -> bool:
	if world == null:
		return false
	if world.has_method("is_tile_blocking"):
		return bool(world.is_tile_blocking(tile, GameConfig.actor_can_swim(skills)))
	var kind = _normalize_tile_kind_name(str(world.get_tile_kind(tile)))
	if GameConfig.actor_can_swim(skills) and kind == "water":
		return false
	return GameConfig.is_blocking_tile_kind(kind)


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


func _finish_tile_interaction_path_step() -> bool:
	if not _path_is_empty():
		_pop_path_step()
		if not _path_is_empty():
			return true

	if world == null:
		return false
	var target_tile = _tile_from_value(current_action.get("tile", []))
	if not _tiles_are_adjacent(world.world_to_tile(global_position), target_tile):
		current_action["path"] = []
		return true
	return false


func _finish_gather_action_step() -> void:
	if str(current_action.get("status", "searching")) == "moving_to_resource":
		var target_tile = _tile_from_value(current_action.get("found_tile", []))
		if _finish_interaction_path_to_tile(target_tile):
			return
		_perform_gather_action()
		return

	if not _path_is_empty():
		_pop_path_step()


func _finish_interaction_path_to_tile(target_tile: Vector2i) -> bool:
	if not _path_is_empty():
		_pop_path_step()
		if not _path_is_empty():
			return true

	if world == null:
		return false
	if not _tiles_are_adjacent(world.world_to_tile(global_position), target_tile):
		current_action["path"] = []
		return true
	return false


func _tile_center(tile_value) -> Vector2:
	var tile = _tile_from_value(tile_value)
	if world != null and world.has_method("tile_center"):
		return world.tile_center(tile)
	return Vector2(float(tile.x) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5, float(tile.y) * GameConfig.TILE_SIZE + GameConfig.TILE_SIZE * 0.5)


func _movement_target_position(tile_value) -> Vector2:
	var tile = _movement_destination_tile(_tile_from_value(tile_value))
	return _tile_center([tile.x, tile.y])


func _movement_destination_tile(target_tile: Vector2i) -> Vector2i:
	if _tile_is_blocking(target_tile):
		return _nearest_interaction_tile(target_tile)
	return target_tile


func _give_item_target_position():
	if follow_target == null:
		return global_position
	if _target_tile_distance() <= GameConfig.AI_ITEM_TRANSFER_DISTANCE_TILES:
		return global_position
	var follow_position = _follow_target_position(true)
	return follow_position if follow_position != null else global_position


func _perform_build_action() -> void:
	if world == null:
		return
	var target_tile = _tile_from_value(current_action.get("tile", []))
	if _tile_occupied_by_actor(target_tile):
		_emit_action_event("build_failed", {
			"action_type": "build_tile",
			"target_tile": [target_tile.x, target_tile.y],
			"status": "failed",
			"reason": "occupied_by_actor",
			"batch_id": current_action.get("batch_id", ""),
			"batch_index": int(current_action.get("batch_index", 1)),
			"batch_count": int(current_action.get("batch_count", 1)),
		})
		return
	var tile_kind = GameConfig.normalize_build_kind(str(current_action.get("tile_kind", "wood_floor")))
	var cost = GameConfig.build_cost(tile_kind)
	if cost.is_empty() or not has_items(cost):
		_emit_action_event("build_failed", {
			"action_type": "build_tile",
			"target_tile": [target_tile.x, target_tile.y],
			"tile_kind": tile_kind,
			"status": "failed",
			"reason": "missing_items",
			"item_cost": cost,
			"batch_id": current_action.get("batch_id", ""),
			"batch_index": int(current_action.get("batch_index", 1)),
			"batch_count": int(current_action.get("batch_count", 1)),
		})
		return

	var result = world.build_tile(target_tile, tile_kind)
	if not bool(result.get("ok", false)):
		_emit_action_event("build_failed", {
			"action_type": "build_tile",
			"target_tile": [target_tile.x, target_tile.y],
			"tile_kind": tile_kind,
			"status": "failed",
			"reason": str(result.get("reason", "unknown")),
			"item_cost": cost,
			"batch_id": current_action.get("batch_id", ""),
			"batch_index": int(current_action.get("batch_index", 1)),
			"batch_count": int(current_action.get("batch_count", 1)),
		})
		return

	consume_items(cost)
	_emit_action_event("build_completed", {
		"action_type": "build_tile",
		"target_tile": [target_tile.x, target_tile.y],
		"tile_kind": tile_kind,
		"status": "completed",
		"item_cost": cost,
		"batch_id": current_action.get("batch_id", ""),
		"batch_index": int(current_action.get("batch_index", 1)),
		"batch_count": int(current_action.get("batch_count", 1)),
	})


func _perform_destroy_action() -> void:
	if world == null:
		return
	var target_tile = _tile_from_value(current_action.get("tile", []))
	var result = world.destroy_tile(target_tile)
	if not bool(result.get("ok", false)):
		_emit_action_event("destroy_failed", {
			"action_type": "destroy_tile",
			"target_tile": [target_tile.x, target_tile.y],
			"status": "failed",
			"reason": str(result.get("reason", "unknown")),
			"batch_id": current_action.get("batch_id", ""),
			"batch_index": int(current_action.get("batch_index", 1)),
			"batch_count": int(current_action.get("batch_count", 1)),
		})
		return

	var removed_kind = str(result.get("removed_kind", ""))
	var refund_value = result.get("refund", GameConfig.build_refund(removed_kind))
	var refund = refund_value.duplicate(true) if typeof(refund_value) == TYPE_DICTIONARY else {}
	var extra = GameConfig.extra_forage_drop(skills, removed_kind)
	for item_id in extra.keys():
		refund[item_id] = int(refund.get(item_id, 0)) + int(extra[item_id])
	add_items(refund)
	_emit_action_event("destroy_completed", {
		"action_type": "destroy_tile",
		"target_tile": [target_tile.x, target_tile.y],
		"tile_kind": removed_kind,
		"source": str(result.get("source", "built")),
		"status": "completed",
		"refund": refund,
		"batch_id": current_action.get("batch_id", ""),
		"batch_index": int(current_action.get("batch_index", 1)),
		"batch_count": int(current_action.get("batch_count", 1)),
	})


func _perform_give_item_action() -> void:
	if follow_target == null or not follow_target.has_method("add_items"):
		_emit_action_event("give_item_failed", {
			"action_type": "give_item",
			"status": "failed",
			"reason": "no_valid_recipient",
		})
		return

	var distance = _target_tile_distance()
	if distance > GameConfig.AI_ITEM_TRANSFER_DISTANCE_TILES:
		_emit_action_event("give_item_failed", {
			"action_type": "give_item",
			"status": "failed",
			"reason": "recipient_too_far",
			"distance_tiles": distance,
		})
		return

	var item_id = _normalize_resource_name(str(current_action.get("item_id", "")))
	var amount = int(clamp(int(current_action.get("amount", 1)), 1, 999))
	if item_id.is_empty():
		_emit_action_event("give_item_failed", {
			"action_type": "give_item",
			"status": "failed",
			"reason": "missing_items",
			"item_id": item_id,
			"amount": amount,
		})
		return

	var stack = {}
	stack[item_id] = amount
	if not has_items(stack):
		_emit_action_event("give_item_failed", {
			"action_type": "give_item",
			"status": "failed",
			"reason": "missing_items",
			"item_id": item_id,
			"amount": amount,
		})
		return

	if not consume_items(stack):
		_emit_action_event("give_item_failed", {
			"action_type": "give_item",
			"status": "failed",
			"reason": "consume_failed",
			"item_id": item_id,
			"amount": amount,
		})
		return

	follow_target.add_items(stack)
	_emit_action_event("action_completed", {
		"action_type": "give_item",
		"status": "completed",
		"item_id": item_id,
		"amount": amount,
		"recipient": "player",
	})


func _perform_gather_action() -> void:
	if world == null:
		return
	var target_tile = _tile_from_value(current_action.get("found_tile", []))
	var expected_kinds = _string_array(current_action.get("target_kinds", []))
	var source_kind = _normalize_tile_kind_name(str(world.get_tile_kind(target_tile)))
	var resource = str(current_action.get("resource", "wood"))
	if not expected_kinds.has(source_kind):
		_emit_action_event("gather_failed", {
			"action_type": "gather_resource",
			"resource": resource,
			"target_tile": [target_tile.x, target_tile.y],
			"tile_kind": source_kind,
			"status": "failed",
			"reason": "resource_tile_changed",
			"gathered": int(current_action.get("gathered", 0)),
			"amount": int(current_action.get("amount", 1)),
		})
		current_action = {}
		return

	var result = world.destroy_tile(target_tile)
	if not bool(result.get("ok", false)):
		_emit_action_event("gather_failed", {
			"action_type": "gather_resource",
			"resource": resource,
			"target_tile": [target_tile.x, target_tile.y],
			"tile_kind": source_kind,
			"status": "failed",
			"reason": str(result.get("reason", "unknown")),
			"gathered": int(current_action.get("gathered", 0)),
			"amount": int(current_action.get("amount", 1)),
		})
		current_action = {}
		return

	var removed_kind = str(result.get("removed_kind", source_kind))
	var refund_value = result.get("refund", GameConfig.terrain_destroy_drop(removed_kind))
	var refund = refund_value.duplicate(true) if typeof(refund_value) == TYPE_DICTIONARY else {}
	var extra = GameConfig.extra_forage_drop(skills, removed_kind)
	for item_id in extra.keys():
		refund[item_id] = int(refund.get(item_id, 0)) + int(extra[item_id])
	add_items(refund)

	var gathered = int(current_action.get("gathered", 0)) + int(refund.get(resource, 0))
	var amount = int(current_action.get("amount", 1))
	current_action["gathered"] = gathered
	var completed = gathered >= amount
	_emit_action_event("gather_completed" if completed else "gather_progress", {
		"action_type": "gather_resource",
		"resource": resource,
		"target_tile": [target_tile.x, target_tile.y],
		"tile_kind": removed_kind,
		"source": str(result.get("source", "terrain")),
		"status": "completed" if completed else "progress",
		"refund": refund,
		"gathered": gathered,
		"amount": amount,
	})

	if completed:
		current_action = {}
	else:
		current_action["path"] = []
		current_action["found_tile"] = []
		current_action["status"] = "searching"


func _has_walkable_adjacent(tile: Vector2i) -> bool:
	for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		if not _tile_is_blocking(tile + direction):
			return true
	return false


func _tile_occupied_by_actor(tile: Vector2i) -> bool:
	if world == null:
		return false
	if world.world_to_tile(global_position) == tile:
		return true
	if follow_target != null and world.world_to_tile(follow_target.global_position) == tile:
		return true
	if world.has_method("actor_overlapping_tiles"):
		for occupied in world.actor_overlapping_tiles(global_position):
			if occupied == tile:
				return true
		if follow_target != null:
			for occupied in world.actor_overlapping_tiles(follow_target.global_position):
				if occupied == tile:
					return true
	return false


func _tick_vitals(delta: float) -> void:
	var moving = velocity.length_squared() > 1.0
	var minutes_delta = delta * GameConfig.GAME_MINUTES_PER_REAL_SECOND
	attributes = GameConfig.tick_vital_attributes(attributes, moving, delta, minutes_delta)


func _nearest_interaction_tile(target_tile: Vector2i) -> Vector2i:
	var current_tile = world.world_to_tile(global_position)
	var candidates = [
		target_tile + Vector2i.RIGHT,
		target_tile + Vector2i.LEFT,
		target_tile + Vector2i.DOWN,
		target_tile + Vector2i.UP,
	]
	var best = current_tile
	var best_distance = INF
	var has_best = false
	for candidate in candidates:
		if _tile_is_blocking(candidate):
			continue
		var distance = Vector2(candidate.x - current_tile.x, candidate.y - current_tile.y).length_squared()
		if not has_best or distance < best_distance:
			best_distance = distance
			best = candidate
			has_best = true
	return best


func _tiles_are_adjacent(a: Vector2i, b: Vector2i) -> bool:
	var delta = a - b
	return abs(delta.x) + abs(delta.y) == 1


func _target_tile_distance() -> int:
	if world == null or follow_target == null:
		return 2147483647
	var self_tile = world.world_to_tile(global_position)
	var target_tile = world.world_to_tile(follow_target.global_position)
	var offset = self_tile - target_tile
	return max(abs(offset.x), abs(offset.y))


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


func _normalize_resource_name(value: String) -> String:
	var lower = value.strip_edges().to_lower()
	match lower:
		"wood", "log", "logs", "timber", "lumber", "木材", "木头", "木板":
			return "wood"
		"stone", "rock", "rocks", "石材", "石头", "石料":
			return "stone"
		_:
			return lower


func _resource_source_kinds(resource: String, explicit_source = "") -> Array:
	var explicit_text = str(explicit_source).strip_edges()
	if not explicit_text.is_empty():
		var explicit_kind = _normalize_tile_kind_name(explicit_text)
		if GameConfig.is_destroyable_terrain_kind(explicit_kind):
			return [explicit_kind]

	var result = []
	for kind in GameConfig.TERRAIN_DESTROY_DROPS.keys():
		var drop = GameConfig.terrain_destroy_drop(str(kind))
		if drop.has(resource):
			result.append(str(kind))
	return result


func _normalize_tile_kind_name(value: String) -> String:
	var lower = value.strip_edges().to_lower()
	match lower:
		"river", "river_water", "water", "水", "河", "河流":
			return "water"
		"grass", "grassland", "草", "草地":
			return "grass"
		"plain", "plains", "平地":
			return "plain"
		"tree", "forest", "woodland", "树", "树木", "森林":
			return "tree"
		"stone_hill", "rock", "rocks", "rocky_hill", "hill", "stone", "石头小山", "石山", "石头", "岩石", "小山":
			return "stone_hill"
		"city", "city_floor", "城区", "城市":
			return "city"
		"city_border", "border", "边界", "城区边界":
			return "city_border"
		"wood_floor", "木地板", "木板", "地板":
			return "wood_floor"
		"stone_floor", "石地板", "石板":
			return "stone_floor"
		"wood_wall", "木墙", "墙":
			return "wood_wall"
		_:
			return lower


func _inventory_from_value(value, fallback: Dictionary) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return fallback.duplicate(true)
	var result = {}
	for key in value.keys():
		var amount = int(value[key])
		if amount > 0:
			result[str(key)] = amount
	return result


func _emit_action_event(event_type: String, payload: Dictionary) -> void:
	var tile = world.world_to_tile(global_position) if world != null else Vector2i.ZERO
	var event = payload.duplicate(true)
	event["event_type"] = event_type
	event["task_id"] = str(current_action.get("task_id", ""))
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
