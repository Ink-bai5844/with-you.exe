class_name PathDebugOverlay
extends Node2D

const GameConfig = preload("res://scripts/config/game_config.gd")

const BLOCK_SCAN_RADIUS = 8

var world
var ai
var player
var active = false


func _ready() -> void:
	z_index = 140
	visible = false


func setup(world_node, ai_node, player_node) -> void:
	world = world_node
	ai = ai_node
	player = player_node


func set_active(value: bool) -> void:
	if active == value:
		return
	active = value
	visible = active
	queue_redraw()


func refresh() -> void:
	if active:
		queue_redraw()


func debug_text() -> String:
	if ai == null:
		return "AI path debug: no ai"
	var action = _current_action()
	var action_type = str(action.get("type", "idle"))
	var path = _path_from_action(action)
	var queue_size = int(ai.action_queue.size())
	var tile = world.world_to_tile(ai.global_position) if world != null else Vector2i.ZERO
	var target_text = _debug_tile_text(action.get("tile", action.get("found_tile", [])))
	var status = str(action.get("status", ""))
	return "PathDebug F3 | AI(%d,%d) action:%s status:%s path:%d queue:%d target:%s" % [
		tile.x,
		tile.y,
		action_type,
		status,
		path.size(),
		queue_size,
		target_text,
	]


func _draw() -> void:
	if not active or world == null or ai == null:
		return

	var tile_size = Vector2(float(world.tile_size), float(world.tile_size))
	var ai_tile = world.world_to_tile(ai.global_position)
	_draw_nearby_blockers(ai_tile, tile_size)
	_draw_actor_tiles(ai.global_position, tile_size)
	_draw_path(tile_size)
	_draw_target_tiles(tile_size)
	_draw_actor_collision(ai.global_position)
	_draw_entity_tile(ai_tile, Color(0.25, 0.70, 1.0, 0.95), tile_size)
	if player != null:
		_draw_entity_tile(world.world_to_tile(player.global_position), Color(1.0, 0.86, 0.28, 0.9), tile_size)


func _draw_nearby_blockers(center: Vector2i, tile_size: Vector2) -> void:
	var fill = Color(1.0, 0.16, 0.12, 0.08)
	var line = Color(1.0, 0.20, 0.16, 0.45)
	for y in range(center.y - BLOCK_SCAN_RADIUS, center.y + BLOCK_SCAN_RADIUS + 1):
		for x in range(center.x - BLOCK_SCAN_RADIUS, center.x + BLOCK_SCAN_RADIUS + 1):
			var tile = Vector2i(x, y)
			if not bool(world.is_tile_blocking(tile)):
				continue
			var rect = Rect2(world.tile_to_world(tile), tile_size)
			draw_rect(rect, fill, true)
			draw_rect(rect, line, false, 1.0)


func _draw_actor_tiles(actor_position: Vector2, tile_size: Vector2) -> void:
	if not world.has_method("actor_overlapping_tiles"):
		return
	var fill = Color(0.85, 0.30, 1.0, 0.12)
	var line = Color(0.85, 0.30, 1.0, 0.78)
	for tile in world.actor_overlapping_tiles(actor_position):
		var rect = Rect2(world.tile_to_world(tile), tile_size)
		draw_rect(rect, fill, true)
		draw_rect(rect, line, false, 1.0)


func _draw_path(tile_size: Vector2) -> void:
	var path = _path_from_action(_current_action())
	if path.is_empty():
		return

	var previous = ai.global_position
	for index in range(path.size()):
		var tile = _tile_from_value(path[index])
		var center = _tile_center(tile)
		var rect = Rect2(world.tile_to_world(tile), tile_size)
		var ratio = float(index) / max(1.0, float(path.size() - 1))
		var fill = Color(0.10, 0.45 + 0.25 * ratio, 1.0, 0.18)
		var line = Color(0.20, 0.68, 1.0, 0.86)
		if index == 0:
			fill = Color(0.20, 1.0, 0.72, 0.34)
			line = Color(0.20, 1.0, 0.72, 1.0)
		draw_rect(rect, fill, true)
		draw_rect(rect, line, false, 1.0 if index != 0 else 2.0)
		draw_line(previous, center, Color(0.18, 0.78, 1.0, 0.95), 2.0)
		draw_circle(center, 2.5, Color(0.18, 0.78, 1.0, 0.95))
		previous = center


func _draw_target_tiles(tile_size: Vector2) -> void:
	var action = _current_action()
	_draw_optional_tile(action.get("tile", []), Color(1.0, 0.43, 0.18, 0.22), Color(1.0, 0.43, 0.18, 1.0), tile_size)
	_draw_optional_tile(action.get("found_tile", []), Color(1.0, 0.90, 0.20, 0.25), Color(1.0, 0.90, 0.20, 1.0), tile_size)
	if str(action.get("type", "")) == "move_to_world":
		var point = action.get("world_position", [])
		if typeof(point) == TYPE_ARRAY and point.size() >= 2:
			draw_circle(Vector2(float(point[0]), float(point[1])), 5.0, Color(1.0, 0.43, 0.18, 1.0))


func _draw_optional_tile(value, fill: Color, line: Color, tile_size: Vector2) -> void:
	var tile = _optional_tile(value)
	if tile == null:
		return
	var rect = Rect2(world.tile_to_world(tile), tile_size)
	draw_rect(rect, fill, true)
	draw_rect(rect, line, false, 2.0)
	draw_line(rect.position, rect.position + rect.size, line, 1.5)
	draw_line(rect.position + Vector2(rect.size.x, 0.0), rect.position + Vector2(0.0, rect.size.y), line, 1.5)


func _draw_actor_collision(actor_position: Vector2) -> void:
	var rect = GameConfig.actor_collision_rect_at(actor_position)
	draw_rect(rect, Color(0.86, 0.20, 1.0, 0.16), true)
	draw_rect(rect, Color(0.86, 0.20, 1.0, 1.0), false, 1.5)


func _draw_entity_tile(tile: Vector2i, color: Color, tile_size: Vector2) -> void:
	var rect = Rect2(world.tile_to_world(tile), tile_size)
	draw_rect(rect, Color(color.r, color.g, color.b, 0.12), true)
	draw_rect(rect.grow(-2.0), color, false, 2.0)


func _current_action() -> Dictionary:
	if ai == null:
		return {}
	var action = ai.current_action
	if typeof(action) == TYPE_DICTIONARY:
		return action
	return {}


func _path_from_action(action: Dictionary) -> Array:
	var path = action.get("path", [])
	return path if typeof(path) == TYPE_ARRAY else []


func _optional_tile(value):
	if typeof(value) == TYPE_VECTOR2I:
		return value
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return null


func _tile_from_value(value) -> Vector2i:
	var tile = _optional_tile(value)
	return tile if tile != null else Vector2i.ZERO


func _tile_center(tile: Vector2i) -> Vector2:
	if world != null and world.has_method("tile_center"):
		return world.tile_center(tile)
	return world.tile_to_world(tile) + Vector2(float(world.tile_size) * 0.5, float(world.tile_size) * 0.5)


func _debug_tile_text(value) -> String:
	var tile = _optional_tile(value)
	if tile == null:
		return "-"
	return "(%d,%d)" % [tile.x, tile.y]
