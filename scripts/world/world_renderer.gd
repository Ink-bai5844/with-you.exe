class_name WorldRenderer
extends Node2D

const GameConfig = preload("res://scripts/config/game_config.gd")
const WorldGeneratorScript = preload("res://scripts/world/world_generator.gd")

const TILE_TEXTURE_DIR = "res://assets/tiles/terrain/default"
const DRAW_TILE_MARGIN = 4
const TILE_CODES = {
	"city": "C",
	"city_border": "B",
	"grass": "G",
	"plain": "P",
	"water": "W",
	"tree": "T",
	"stone_hill": "H",
	"wood_floor": "F",
	"stone_floor": "S",
	"wood_wall": "X",
}
const TILE_LEGEND = {
	"C": "city_floor",
	"B": "city_border",
	"G": "grass",
	"P": "plain",
	"W": "river_water",
	"T": "tree",
	"H": "stone_hill",
	"F": "wood_floor",
	"S": "stone_floor",
	"X": "wood_wall",
}
const TRANSPARENT_TEXTURE_BASE_KINDS = {
	"tree": "grass",
	"stone_hill": "plain",
}
const RAY_DIRECTIONS = [
	{"id": "north", "label": "up", "vector": Vector2i(0, -1)},
	{"id": "north_east", "label": "up_right", "vector": Vector2i(1, -1)},
	{"id": "east", "label": "right", "vector": Vector2i(1, 0)},
	{"id": "south_east", "label": "down_right", "vector": Vector2i(1, 1)},
	{"id": "south", "label": "down", "vector": Vector2i(0, 1)},
	{"id": "south_west", "label": "down_left", "vector": Vector2i(-1, 1)},
	{"id": "west", "label": "left", "vector": Vector2i(-1, 0)},
	{"id": "north_west", "label": "up_left", "vector": Vector2i(-1, -1)},
]

var generator = WorldGeneratorScript.new()
var tile_size = GameConfig.TILE_SIZE
var tile_overrides = {}
var terrain_overrides = {}
var _tile_kind_cache = {}
var _tile_textures = {}
var _last_draw_center = Vector2i(2147483647, 2147483647)
var _last_draw_half_size = Vector2i.ZERO
var _last_draw_view_size = Vector2.ZERO
var _last_draw_camera_zoom = Vector2.ZERO


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_seed(seed_value: int) -> void:
	generator = WorldGeneratorScript.new(seed_value)
	_tile_kind_cache.clear()
	_reset_draw_tracking()
	queue_redraw()


func get_seed() -> int:
	return int(generator.seed_value)


func get_save_data() -> Dictionary:
	return {
		"seed": get_seed(),
		"tile_overrides": _tile_overrides_to_save(),
		"terrain_overrides": _terrain_overrides_to_save(),
	}


func apply_save_data(data: Dictionary) -> void:
	set_seed(int(data.get("seed", GameConfig.DEFAULT_WORLD_SEED)))
	tile_overrides.clear()
	terrain_overrides.clear()
	var overrides = data.get("tile_overrides", [])
	if typeof(overrides) == TYPE_ARRAY:
		for entry in overrides:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var tile_value = entry.get("tile", [])
			if typeof(tile_value) != TYPE_ARRAY or tile_value.size() < 2:
				continue
			var kind = GameConfig.normalize_build_kind(str(entry.get("kind", "")))
			if not GameConfig.BUILDABLE_TILE_KINDS.has(kind):
				continue
			var tile = Vector2i(int(tile_value[0]), int(tile_value[1]))
			tile_overrides[_tile_key(tile)] = kind
	var terrain_changes = data.get("terrain_overrides", [])
	if typeof(terrain_changes) == TYPE_ARRAY:
		for entry in terrain_changes:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var tile_value = entry.get("tile", [])
			if typeof(tile_value) != TYPE_ARRAY or tile_value.size() < 2:
				continue
			var kind = GameConfig.normalize_build_kind(str(entry.get("kind", "")))
			if not GameConfig.TERRAIN_TILE_KINDS.has(kind):
				continue
			var tile = Vector2i(int(tile_value[0]), int(tile_value[1]))
			terrain_overrides[_tile_key(tile)] = kind
	queue_redraw()


func world_to_tile(world_position: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_position.x / tile_size)), int(floor(world_position.y / tile_size)))


func tile_to_world(tile: Vector2i) -> Vector2:
	return Vector2(float(tile.x * tile_size), float(tile.y * tile_size))


func tile_center(tile: Vector2i) -> Vector2:
	return tile_to_world(tile) + Vector2(float(tile_size) * 0.5, float(tile_size) * 0.5)


func actor_overlapping_tiles(actor_position: Vector2) -> Array[Vector2i]:
	var rect = GameConfig.actor_collision_rect_at(actor_position)
	var epsilon = 0.001
	var min_tile = world_to_tile(rect.position + Vector2(epsilon, epsilon))
	var max_tile = world_to_tile(rect.position + rect.size - Vector2(epsilon, epsilon))
	var result: Array[Vector2i] = []
	for y in range(min_tile.y, max_tile.y + 1):
		for x in range(min_tile.x, max_tile.x + 1):
			result.append(Vector2i(x, y))
	return result


func is_actor_position_blocked(actor_position: Vector2, can_swim: bool = false) -> bool:
	for tile in actor_overlapping_tiles(actor_position):
		if is_tile_blocking(tile, can_swim):
			return true
	return false


func encode_area(center: Vector2i, radius: int) -> Dictionary:
	return encode_area_rect(center, radius * 2 + 1, radius * 2 + 1)


func encode_area_size(center: Vector2i, size: int) -> Dictionary:
	var clamped_size = max(1, size)
	return encode_area_rect(center, clamped_size, clamped_size)


func encode_area_rect(center: Vector2i, width: int, height: int) -> Dictionary:
	var clamped_width = max(1, width)
	var clamped_height = max(1, height)
	var origin = Vector2i(center.x - int(floor(float(clamped_width) * 0.5)), center.y - int(floor(float(clamped_height) * 0.5)))
	return encode_area_bounds(origin, Vector2i(origin.x + clamped_width - 1, origin.y + clamped_height - 1))


func encode_area_bounds(first_tile: Vector2i, second_tile: Vector2i) -> Dictionary:
	var origin = Vector2i(min(first_tile.x, second_tile.x), min(first_tile.y, second_tile.y))
	var end = Vector2i(max(first_tile.x, second_tile.x), max(first_tile.y, second_tile.y))
	var width = end.x - origin.x + 1
	var height = end.y - origin.y + 1
	var rows: Array[String] = []
	var counts = {}
	var notable_tiles = []
	for y in range(origin.y, end.y + 1):
		var row = ""
		for x in range(origin.x, end.x + 1):
			var tile = Vector2i(x, y)
			var kind = get_tile_kind(tile)
			row += get_tile_code(tile)
			counts[kind] = int(counts.get(kind, 0)) + 1
			if _tile_should_be_notable(tile, kind):
				notable_tiles.append(_tile_area_payload(tile))
		rows.append(row)
	return {
		"origin": [origin.x, origin.y],
		"end": [end.x, end.y],
		"center": [origin.x + int(floor(float(width) * 0.5)), origin.y + int(floor(float(height) * 0.5))],
		"radius": int(floor(float(max(width, height)) * 0.5)),
		"size": [width, height],
		"width": width,
		"height": height,
		"legend": TILE_LEGEND.duplicate(true),
		"counts": counts,
		"notable_tiles": notable_tiles,
		"rows": rows,
	}


func encode_rays(center: Vector2i, max_length: int) -> Dictionary:
	var clamped_length = max(1, max_length)
	var rays = []
	for direction in RAY_DIRECTIONS:
		var direction_vector: Vector2i = direction["vector"]
		var seen_kinds = {}
		var hits = []
		for distance in range(1, clamped_length + 1):
			var tile = center + direction_vector * distance
			var kind = get_tile_kind(tile)
			if seen_kinds.has(kind):
				continue
			seen_kinds[kind] = true
			hits.append(_tile_sensor_payload(tile, distance))
		rays.append({
			"direction": str(direction["id"]),
			"label": str(direction["label"]),
			"vector": [direction_vector.x, direction_vector.y],
			"hits": hits,
		})
	return {
		"origin": [center.x, center.y],
		"max_length": clamped_length,
		"rule": "Each ray reports only the earliest tile where a not-yet-seen tile kind appears along that direction.",
		"directions": rays,
	}


func _tile_sensor_payload(tile: Vector2i, distance: int) -> Dictionary:
	var payload = _tile_area_payload(tile)
	payload["distance"] = distance
	return payload


func _tile_area_payload(tile: Vector2i) -> Dictionary:
	var kind = get_tile_kind(tile)
	var blocking = GameConfig.is_blocking_tile_kind(kind)
	var built = tile_overrides.has(_tile_key(tile))
	return {
		"tile": [tile.x, tile.y],
		"kind": kind,
		"code": get_tile_code(tile),
		"blocking": blocking,
		"walkable": not blocking,
		"buildable": GameConfig.BUILDABLE_TILE_KINDS.has(GameConfig.normalize_build_kind(kind)),
		"can_build_tile_kinds": _buildable_tile_kinds_for_base(tile),
		"destroyable": built or GameConfig.is_destroyable_terrain_kind(kind),
		"terrain": GameConfig.TERRAIN_TILE_KINDS.has(kind),
		"built": built,
		"terrain_modified": terrain_overrides.has(_tile_key(tile)),
	}


func _tile_should_be_notable(tile: Vector2i, kind: String) -> bool:
	if tile_overrides.has(_tile_key(tile)) or terrain_overrides.has(_tile_key(tile)):
		return true
	return kind == "water" or GameConfig.is_blocking_tile_kind(kind) or GameConfig.is_destroyable_terrain_kind(kind)


func _buildable_tile_kinds_for_base(tile: Vector2i) -> Array:
	if tile_overrides.has(_tile_key(tile)):
		return []
	var base_kind = _base_tile_kind(tile)
	var result = []
	for kind in GameConfig.BUILDABLE_TILE_KINDS:
		if GameConfig.can_build_on_base(str(kind), base_kind):
			result.append(str(kind))
	return result


func get_tile_kind(tile: Vector2i) -> String:
	var key = _tile_key(tile)
	if tile_overrides.has(key):
		return str(tile_overrides[key])
	if terrain_overrides.has(key):
		return str(terrain_overrides[key])
	if _tile_kind_cache.has(key):
		return str(_tile_kind_cache[key])
	var kind = generator.get_tile_kind(tile)
	if _tile_kind_cache.size() >= GameConfig.TILE_KIND_CACHE_LIMIT:
		_tile_kind_cache.clear()
	_tile_kind_cache[key] = kind
	return kind


func is_tile_blocking(tile: Vector2i, can_swim: bool = false) -> bool:
	var kind = get_tile_kind(tile)
	if can_swim and str(kind) == "water":
		return false
	return GameConfig.is_blocking_tile_kind(kind)


func get_tile_code(tile: Vector2i) -> String:
	return str(TILE_CODES.get(get_tile_kind(tile), "G"))


func _base_tile_kind(tile: Vector2i) -> String:
	var key = _tile_key(tile)
	if terrain_overrides.has(key):
		return str(terrain_overrides[key])
	return generator.get_tile_kind(tile)


func build_tile(tile: Vector2i, kind: String) -> Dictionary:
	var normalized = GameConfig.normalize_build_kind(kind)
	if not GameConfig.BUILDABLE_TILE_KINDS.has(normalized):
		return {"ok": false, "reason": "not_buildable"}
	var key = _tile_key(tile)
	if tile_overrides.has(key):
		return {"ok": false, "reason": "occupied", "existing_kind": tile_overrides[key]}
	var base_kind = _base_tile_kind(tile)
	if not GameConfig.can_build_on_base(normalized, base_kind):
		return {"ok": false, "reason": "invalid_base_tile", "base_kind": base_kind}
	tile_overrides[key] = normalized
	queue_redraw()
	return {
		"ok": true,
		"tile": [tile.x, tile.y],
		"kind": normalized,
		"base_kind": base_kind,
	}


func destroy_tile(tile: Vector2i) -> Dictionary:
	var key = _tile_key(tile)
	if tile_overrides.has(key):
		var removed_kind = str(tile_overrides[key])
		tile_overrides.erase(key)
		queue_redraw()
		return {
			"ok": true,
			"tile": [tile.x, tile.y],
			"removed_kind": removed_kind,
			"refund": GameConfig.build_refund(removed_kind),
			"source": "built",
		}

	var base_kind = _base_tile_kind(tile)
	if not GameConfig.is_destroyable_terrain_kind(base_kind):
		return {"ok": false, "reason": "no_destroyable_tile", "base_kind": base_kind}

	var replacement = GameConfig.terrain_destroy_replacement(base_kind)
	terrain_overrides[key] = replacement
	_tile_kind_cache.erase(key)
	queue_redraw()
	return {
		"ok": true,
		"tile": [tile.x, tile.y],
		"removed_kind": base_kind,
		"replacement_kind": replacement,
		"refund": GameConfig.terrain_destroy_drop(base_kind),
		"source": "terrain",
	}


func _process(_delta: float) -> void:
	if _draw_window_changed():
		queue_redraw()


func _draw_window_changed() -> bool:
	var camera = get_viewport().get_camera_2d()
	var camera_position = Vector2.ZERO
	var camera_zoom = Vector2.ONE
	if camera != null:
		camera_position = camera.global_position
		camera_zoom = camera.zoom

	var view_size = get_viewport_rect().size / camera_zoom
	var center = world_to_tile(camera_position)
	var half_size = Vector2i(
		int(ceil(view_size.x / float(tile_size) * 0.5)) + DRAW_TILE_MARGIN,
		int(ceil(view_size.y / float(tile_size) * 0.5)) + DRAW_TILE_MARGIN
	)

	if center == _last_draw_center and half_size == _last_draw_half_size and view_size == _last_draw_view_size and camera_zoom == _last_draw_camera_zoom:
		return false

	_last_draw_center = center
	_last_draw_half_size = half_size
	_last_draw_view_size = view_size
	_last_draw_camera_zoom = camera_zoom
	return true


func _reset_draw_tracking() -> void:
	_last_draw_center = Vector2i(2147483647, 2147483647)
	_last_draw_half_size = Vector2i.ZERO
	_last_draw_view_size = Vector2.ZERO
	_last_draw_camera_zoom = Vector2.ZERO


func _draw() -> void:
	var camera = get_viewport().get_camera_2d()
	var camera_position = Vector2.ZERO
	var camera_zoom = Vector2.ONE
	if camera != null:
		camera_position = camera.global_position
		camera_zoom = camera.zoom

	var view_size = get_viewport_rect().size / camera_zoom
	var center = world_to_tile(camera_position)
	var half_x = int(ceil(view_size.x / float(tile_size) * 0.5)) + DRAW_TILE_MARGIN
	var half_y = int(ceil(view_size.y / float(tile_size) * 0.5)) + DRAW_TILE_MARGIN

	for y in range(center.y - half_y, center.y + half_y + 1):
		for x in range(center.x - half_x, center.x + half_x + 1):
			var tile = Vector2i(x, y)
			var kind = get_tile_kind(tile)
			var rect = Rect2(tile_to_world(tile), Vector2(tile_size, tile_size))
			_draw_tile(tile, rect, kind)

	var city_rect = Rect2(
		Vector2(-GameConfig.CITY_HALF_SIZE * tile_size, -GameConfig.CITY_HALF_SIZE * tile_size),
		Vector2(GameConfig.CITY_SIZE * tile_size, GameConfig.CITY_SIZE * tile_size)
	)
	draw_rect(city_rect, Color("111820"), false, 3.0)
	draw_line(Vector2(city_rect.position.x, 0.0), Vector2(city_rect.position.x + city_rect.size.x, 0.0), Color("aeb8c2"), 1.0)
	draw_line(Vector2(0.0, city_rect.position.y), Vector2(0.0, city_rect.position.y + city_rect.size.y), Color("aeb8c2"), 1.0)


func _tile_color(kind: String) -> Color:
	match kind:
		"wood_floor":
			return Color("8a5a32")
		"stone_floor":
			return Color("7b838a")
		"wood_wall":
			return Color("5a3824")
		_:
			return generator.tile_color(kind)


func _draw_tile(tile: Vector2i, rect: Rect2, kind: String) -> void:
	var texture = _tile_texture(kind)
	if texture != null:
		_draw_texture_underlay(tile, rect, kind)
		draw_texture_rect(texture, rect, false)
		return
	_draw_fallback_tile(tile, rect, kind)


func _draw_texture_underlay(tile: Vector2i, rect: Rect2, kind: String) -> void:
	var key = _tile_key(tile)
	if tile_overrides.has(key):
		_draw_underlay_kind(tile, rect, _base_tile_kind(tile))
		return

	var underlay_kind = str(TRANSPARENT_TEXTURE_BASE_KINDS.get(kind, ""))
	if not underlay_kind.is_empty():
		_draw_underlay_kind(tile, rect, underlay_kind)
		return

	draw_rect(rect, _tile_color(kind), true)


func _draw_underlay_kind(tile: Vector2i, rect: Rect2, kind: String) -> void:
	draw_rect(rect, _tile_color(kind), true)
	var texture = _tile_texture(kind)
	if texture != null:
		draw_texture_rect(texture, rect, false)
		return
	_draw_fallback_details(tile, rect, kind)


func _draw_fallback_tile(tile: Vector2i, rect: Rect2, kind: String) -> void:
	draw_rect(rect, _tile_color(kind), true)
	_draw_fallback_details(tile, rect, kind)


func _draw_fallback_details(tile: Vector2i, rect: Rect2, kind: String) -> void:
	if kind == WorldGeneratorScript.TILE_GRASS and _detail_dot(tile):
		draw_rect(Rect2(rect.position + Vector2(6, 4), Vector2(2, 2)), Color("2e6c36"), true)
	elif kind == WorldGeneratorScript.TILE_PLAIN and _detail_dot(tile):
		draw_rect(Rect2(rect.position + Vector2(3, 10), Vector2(3, 1)), Color("678e50"), true)
	elif kind == WorldGeneratorScript.TILE_TREE:
		_draw_tree_tile(rect)
	elif kind == WorldGeneratorScript.TILE_STONE_HILL:
		_draw_stone_hill_tile(rect)


func _draw_tree_tile(rect: Rect2) -> void:
	draw_rect(Rect2(rect.position + Vector2(7, 8), Vector2(2, 6)), Color("5a3824"), true)
	draw_rect(Rect2(rect.position + Vector2(4, 3), Vector2(8, 8)), Color("1f5f32"), true)
	draw_rect(Rect2(rect.position + Vector2(2, 6), Vector2(12, 6)), Color("2f7d3c"), true)
	draw_rect(Rect2(rect.position + Vector2(6, 2), Vector2(4, 3)), Color("4a9a4f"), true)
	draw_rect(Rect2(rect.position + Vector2(4, 12), Vector2(8, 2)), Color("214f2d"), true)


func _draw_stone_hill_tile(rect: Rect2) -> void:
	draw_rect(Rect2(rect.position + Vector2(3, 7), Vector2(10, 6)), Color("5f6867"), true)
	draw_rect(Rect2(rect.position + Vector2(5, 4), Vector2(7, 4)), Color("87908e"), true)
	draw_rect(Rect2(rect.position + Vector2(2, 10), Vector2(12, 3)), Color("4f5655"), true)
	draw_rect(Rect2(rect.position + Vector2(6, 5), Vector2(3, 2)), Color("aab2af"), true)


func _detail_dot(tile: Vector2i) -> bool:
	var raw = sin(float(tile.x * 17 + tile.y * 43 + generator.seed_value) * 0.73) * 10000.0
	return raw - floor(raw) > 0.72


func _tile_key(tile: Vector2i) -> String:
	return "%d,%d" % [tile.x, tile.y]


func _tile_from_key(key: String) -> Vector2i:
	var parts = key.split(",", false)
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


func _tile_overrides_to_save() -> Array:
	var result = []
	for key in tile_overrides.keys():
		var tile = _tile_from_key(str(key))
		result.append({
			"tile": [tile.x, tile.y],
			"kind": str(tile_overrides[key]),
		})
	return result


func _terrain_overrides_to_save() -> Array:
	var result = []
	for key in terrain_overrides.keys():
		var tile = _tile_from_key(str(key))
		result.append({
			"tile": [tile.x, tile.y],
			"kind": str(terrain_overrides[key]),
		})
	return result


func _tile_texture(kind: String) -> Texture2D:
	if _tile_textures.has(kind):
		return _tile_textures[kind]
	for extension in ["png", "webp", "jpg", "jpeg"]:
		var path = "%s/%s.%s" % [TILE_TEXTURE_DIR, kind, extension]
		var texture = _load_texture(path)
		if texture != null:
			_tile_textures[kind] = texture
			return texture
	_tile_textures[kind] = null
	return null


func _load_texture(path: String) -> Texture2D:
	var loaded = load(path) if ResourceLoader.exists(path) else null
	if loaded is Texture2D:
		return loaded
	if not FileAccess.file_exists(path):
		return null
	var image = Image.new()
	if image.load(path) != OK:
		return null
	return ImageTexture.create_from_image(image)
