class_name Player
extends CharacterBody2D

signal stats_changed(snapshot)

const GameConfig = preload("res://scripts/config/game_config.gd")
const PixelActorViewScene = preload("res://scripts/visual/pixel_actor_view.gd")

const COLLISION_LAYER_PLAYER = 1
const COLLISION_MASK_WORLD = 4

var speed = GameConfig.PLAYER_SPEED
var controls_enabled = false
var profile = {}
var attributes = {"health": 100, "energy": 90, "hunger": 10, "focus": 50}
var skills = []
var facing = "down"

var _view


func _ready() -> void:
	collision_layer = COLLISION_LAYER_PLAYER
	collision_mask = COLLISION_MASK_WORLD

	_view = PixelActorViewScene.new()
	_view.set_player_skin()
	add_child(_view)

	var shape = RectangleShape2D.new()
	shape.size = Vector2(10, 12)
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.position = Vector2(0, 0)
	add_child(collision)


func apply_preset(preset: Dictionary) -> void:
	profile = preset.duplicate(true)
	attributes = profile.get("attributes", {}).duplicate(true)
	skills = profile.get("skills", []).duplicate(true)
	stats_changed.emit(get_state())


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
	var position = data.get("position", [0.0, 0.0])
	if typeof(position) == TYPE_ARRAY and position.size() >= 2:
		global_position = Vector2(float(position[0]), float(position[1]))
	facing = str(data.get("facing", "down"))
	if _view != null:
		_view.set_direction(facing)
	stats_changed.emit(get_state())


func get_save_data() -> Dictionary:
	return {
		"profile": profile.duplicate(true),
		"profile_id": profile.get("id", "unset"),
		"name": profile.get("name", "玩家"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"facing": facing,
	}


func set_controls_enabled(value: bool) -> void:
	controls_enabled = value


func _physics_process(_delta: float) -> void:
	if not controls_enabled or _is_typing():
		velocity = Vector2.ZERO
		move_and_slide()
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

	velocity = input_vector.normalized() * speed
	if input_vector.length_squared() > 0.0:
		_update_facing(input_vector)
	move_and_slide()


func get_state() -> Dictionary:
	return {
		"profile_id": profile.get("id", "unset"),
		"name": profile.get("name", "玩家"),
		"position": [global_position.x, global_position.y],
		"attributes": attributes.duplicate(true),
		"skills": skills.duplicate(true),
		"facing": facing,
	}


func _update_facing(input_vector: Vector2) -> void:
	if abs(input_vector.x) > abs(input_vector.y):
		facing = "right" if input_vector.x > 0.0 else "left"
	else:
		facing = "down" if input_vector.y > 0.0 else "up"
	_view.set_direction(facing)


func _is_typing() -> bool:
	var focus = get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit
