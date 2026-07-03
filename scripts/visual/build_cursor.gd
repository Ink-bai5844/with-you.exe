class_name BuildCursor
extends Node2D

const GameConfig = preload("res://scripts/config/game_config.gd")

var world
var player
var active = false
var radius = GameConfig.PLAYER_BUILD_RADIUS
var hovered_tile = Vector2i.ZERO
var hovered_valid = false
var selected_kind = ""


func _ready() -> void:
	z_index = 100
	visible = false


func setup(world_node, player_node) -> void:
	world = world_node
	player = player_node


func set_state(is_active: bool, tile: Vector2i, is_valid: bool, tile_kind: String, build_radius: int) -> void:
	var clamped_radius = max(0, build_radius)
	if active == is_active and hovered_tile == tile and hovered_valid == is_valid and selected_kind == tile_kind and radius == clamped_radius:
		return
	active = is_active
	hovered_tile = tile
	hovered_valid = is_valid
	selected_kind = tile_kind
	radius = clamped_radius
	visible = active
	queue_redraw()


func _draw() -> void:
	if not active or world == null or player == null:
		return

	var player_tile = world.world_to_tile(player.global_position)
	var tile_size = Vector2(float(world.tile_size), float(world.tile_size))
	var range_line = Color(0.37, 0.72, 0.95, 0.35)
	var range_fill = Color(0.37, 0.72, 0.95, 0.06)
	var valid_fill = Color(0.20, 0.86, 0.64, 0.24)
	var valid_line = Color(0.20, 0.86, 0.64, 0.95)
	var invalid_fill = Color(0.95, 0.24, 0.24, 0.24)
	var invalid_line = Color(0.95, 0.24, 0.24, 0.95)

	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if x == 0 and y == 0:
				continue
			var tile = player_tile + Vector2i(x, y)
			var rect = Rect2(world.tile_to_world(tile), tile_size)
			var is_hovered = tile == hovered_tile
			if is_hovered:
				draw_rect(rect, valid_fill if hovered_valid else invalid_fill, true)
				draw_rect(rect, valid_line if hovered_valid else invalid_line, false, 2.0)
			else:
				draw_rect(rect, range_fill, true)
				draw_rect(rect, range_line, false, 1.0)
