class_name Player
extends CharacterBody2D

signal stats_changed(snapshot)
signal inventory_changed(snapshot)

const GameConfig = preload("res://scripts/config/game_config.gd")
const PixelActorViewScene = preload("res://scripts/visual/pixel_actor_view.gd")

const COLLISION_LAYER_PLAYER = 1
const COLLISION_MASK_WORLD = 4

var speed = GameConfig.PLAYER_SPEED
var controls_enabled = false
var profile = {}
var attributes = {"health": 100, "energy": 90, "hunger": 10, "focus": 50}
var skills = []
var inventory = GameConfig.DEFAULT_PLAYER_INVENTORY.duplicate(true)
var facing = "down"
var world

var _view


func _ready() -> void:
	collision_layer = COLLISION_LAYER_PLAYER
	collision_mask = COLLISION_MASK_WORLD

	_view = PixelActorViewScene.new()
	_view.set_player_skin()
	add_child(_view)

	var shape = RectangleShape2D.new()
	shape.size = GameConfig.actor_collision_size()
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.position = GameConfig.actor_collision_position()
	add_child(collision)


func apply_preset(preset: Dictionary) -> void:
	profile = preset.duplicate(true)
	attributes = profile.get("attributes", {}).duplicate(true)
	skills = profile.get("skills", []).duplicate(true)
	inventory = _inventory_from_value(profile.get("inventory", GameConfig.DEFAULT_PLAYER_INVENTORY), GameConfig.DEFAULT_PLAYER_INVENTORY)
	stats_changed.emit(get_state())
	inventory_changed.emit(inventory.duplicate(true))


func apply_save_data(data: Dictionary) -> void:
	if typeof(data.get("profile", null)) == TYPE_DICTIONARY:
		profile = data["profile"].duplicate(true)
	else:
		profile = {
			"id": str(data.get("profile_id", "loaded_player")),
			"name": str(data.get("name", "玩家")),
		}
	attributes = data.get("attributes", attributes).duplicate(true)
	skills = data.get("skills", skills).duplicate(true)
	inventory = _inventory_from_value(data.get("inventory", GameConfig.DEFAULT_PLAYER_INVENTORY), GameConfig.DEFAULT_PLAYER_INVENTORY)
	var position = data.get("position", [0.0, 0.0])
	if typeof(position) == TYPE_ARRAY and position.size() >= 2:
		global_position = Vector2(float(position[0]), float(position[1]))
	facing = str(data.get("facing", "down"))
	if _view != null:
		_view.set_direction(facing)
	stats_changed.emit(get_state())
	inventory_changed.emit(inventory.duplicate(true))


func get_save_data() -> Dictionary:
	return {
		"profile": profile.duplicate(true),
		"profile_id": profile.get("id", "unset"),
		"name": profile.get("name", "玩家"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"inventory": inventory.duplicate(true),
		"facing": facing,
	}


func set_controls_enabled(value: bool) -> void:
	controls_enabled = value
	if not value and _view != null:
		_view.set_moving(false)


func set_world(world_node) -> void:
	world = world_node


func _physics_process(delta: float) -> void:
	if not controls_enabled:
		velocity = Vector2.ZERO
		if _view != null:
			_view.set_moving(false)
		return
	if _is_typing():
		velocity = Vector2.ZERO
		_tick_vitals(delta, false)
		if _view != null:
			_view.set_moving(false)
		return

	var input_vector = Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"):
		input_vector.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"):
		input_vector.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_action_pressed("ui_up"):
		input_vector.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_action_pressed("ui_down"):
		input_vector.y += 1.0

	speed = GameConfig.PLAYER_SPEED * GameConfig.actor_speed_scale(attributes)
	velocity = input_vector.normalized() * speed
	if input_vector.length_squared() > 0.0:
		_update_facing(input_vector)
	_move_with_world_collision(delta)
	var moving = velocity.length_squared() > 1.0
	_tick_vitals(delta, moving)
	if _view != null:
		_view.set_moving(moving)


func get_state() -> Dictionary:
	return {
		"profile_id": profile.get("id", "unset"),
		"name": profile.get("name", "玩家"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"inventory": inventory.duplicate(true),
		"facing": facing,
		"can_swim": GameConfig.actor_can_swim(skills),
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


func front_tile(world_node) -> Vector2i:
	var tile = world_node.world_to_tile(global_position)
	return tile + _facing_tile_offset()


func _update_facing(input_vector: Vector2) -> void:
	if abs(input_vector.x) > abs(input_vector.y):
		facing = "right" if input_vector.x > 0.0 else "left"
	else:
		facing = "down" if input_vector.y > 0.0 else "up"
	_view.set_direction(facing)


func _is_typing() -> bool:
	var focus = get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


func _inventory_from_value(value, fallback: Dictionary) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return fallback.duplicate(true)
	var result = {}
	for key in value.keys():
		var amount = int(value[key])
		if amount > 0:
			result[str(key)] = amount
	return result


func _facing_tile_offset() -> Vector2i:
	match facing:
		"right":
			return Vector2i.RIGHT
		"left":
			return Vector2i.LEFT
		"up":
			return Vector2i.UP
		_:
			return Vector2i.DOWN


func _tick_vitals(delta: float, moving: bool) -> void:
	var minutes_delta = delta * GameConfig.GAME_MINUTES_PER_REAL_SECOND
	attributes = GameConfig.tick_vital_attributes(attributes, moving, delta, minutes_delta)


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
	var kind = str(world.get_tile_kind(target_tile))
	if GameConfig.actor_can_swim(skills) and kind == "water":
		return false
	return GameConfig.is_blocking_tile_kind(kind)
