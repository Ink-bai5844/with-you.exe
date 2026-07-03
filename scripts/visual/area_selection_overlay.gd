class_name AreaSelectionOverlay
extends Node2D

var world
var active = false
var has_selection = false
var start_tile = Vector2i.ZERO
var end_tile = Vector2i.ZERO


func _ready() -> void:
	z_index = 95
	visible = false


func setup(world_node) -> void:
	world = world_node


func set_drag(start: Vector2i, current: Vector2i) -> void:
	start_tile = start
	end_tile = current
	active = true
	has_selection = false
	visible = true
	queue_redraw()


func set_selection(start: Vector2i, current: Vector2i) -> void:
	start_tile = start
	end_tile = current
	active = false
	has_selection = true
	visible = true
	queue_redraw()


func clear() -> void:
	active = false
	has_selection = false
	visible = false
	queue_redraw()


func _draw() -> void:
	if world == null or (not active and not has_selection):
		return

	var min_tile = Vector2i(min(start_tile.x, end_tile.x), min(start_tile.y, end_tile.y))
	var max_tile = Vector2i(max(start_tile.x, end_tile.x), max(start_tile.y, end_tile.y))
	var tile_size = float(world.tile_size)
	var rect = Rect2(
		world.tile_to_world(min_tile),
		Vector2(float(max_tile.x - min_tile.x + 1) * tile_size, float(max_tile.y - min_tile.y + 1) * tile_size)
	)
	var fill = Color(0.95, 0.78, 0.20, 0.16) if has_selection else Color(0.95, 0.78, 0.20, 0.10)
	var line = Color(1.0, 0.86, 0.32, 0.95) if has_selection else Color(1.0, 0.86, 0.32, 0.75)
	draw_rect(rect, fill, true)
	draw_rect(rect, line, false, 2.0)
