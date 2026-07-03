class_name WorldGenerator
extends RefCounted

const GameConfig = preload("res://scripts/config/game_config.gd")

const TILE_CITY = "city"
const TILE_CITY_BORDER = "city_border"
const TILE_GRASS = "grass"
const TILE_PLAIN = "plain"
const TILE_WATER = "water"
const TILE_TREE = "tree"
const TILE_STONE_HILL = "stone_hill"

var seed_value = GameConfig.DEFAULT_WORLD_SEED


func _init(new_seed = GameConfig.DEFAULT_WORLD_SEED) -> void:
	seed_value = int(new_seed)


func get_tile_kind(coord: Vector2i) -> String:
	if abs(coord.x) <= GameConfig.CITY_HALF_SIZE and abs(coord.y) <= GameConfig.CITY_HALF_SIZE:
		if abs(coord.x) == GameConfig.CITY_HALF_SIZE or abs(coord.y) == GameConfig.CITY_HALF_SIZE:
			return TILE_CITY_BORDER
		return TILE_CITY

	var river_center = _river_center_y(coord.x)
	var river_width = 2.0 + _value_noise(float(coord.x) * 0.06, 31.7) * 3.0
	if abs(float(coord.y) - river_center) <= river_width:
		return TILE_WATER

	var ground = _fbm(float(coord.x) * 0.075, float(coord.y) * 0.075, 4)
	var ground_kind = TILE_PLAIN if ground < 0.43 else TILE_GRASS

	var stone_zone = _fbm(float(coord.x) * 0.045 + 93.1, float(coord.y) * 0.045 - 47.6, 4)
	var stone_detail = _value_noise(float(coord.x) * 0.41 + 19.5, float(coord.y) * 0.41 - 8.3)
	if ground_kind == TILE_PLAIN and stone_zone > 0.64 and stone_detail > 0.42:
		return TILE_STONE_HILL

	var forest_zone = _fbm(float(coord.x) * 0.055 - 31.4, float(coord.y) * 0.055 + 58.2, 4)
	var tree_detail = _hash_to_unit(coord.x * 3 + 17, coord.y * 5 - 23)
	if ground_kind == TILE_GRASS and forest_zone > 0.56 and tree_detail > 0.52:
		return TILE_TREE

	return ground_kind


func get_tile_code(coord: Vector2i) -> String:
	match get_tile_kind(coord):
		TILE_CITY:
			return "C"
		TILE_CITY_BORDER:
			return "B"
		TILE_WATER:
			return "W"
		TILE_TREE:
			return "T"
		TILE_STONE_HILL:
			return "H"
		TILE_PLAIN:
			return "P"
		_:
			return "G"


func tile_color(kind: String) -> Color:
	match kind:
		TILE_CITY:
			return Color("657178")
		TILE_CITY_BORDER:
			return Color("d8dde2")
		TILE_WATER:
			return Color("2477b8")
		TILE_TREE:
			return Color("286b35")
		TILE_STONE_HILL:
			return Color("777f7d")
		TILE_PLAIN:
			return Color("80a85f")
		_:
			return Color("3f8d49")


func encode_area(center: Vector2i, radius: int) -> Dictionary:
	var rows: Array[String] = []
	for y in range(center.y - radius, center.y + radius + 1):
		var row = ""
		for x in range(center.x - radius, center.x + radius + 1):
			row += get_tile_code(Vector2i(x, y))
		rows.append(row)
	return {
		"origin": [center.x - radius, center.y - radius],
		"center": [center.x, center.y],
		"radius": radius,
		"width": radius * 2 + 1,
		"height": radius * 2 + 1,
		"legend": {"C": "city_floor", "B": "city_border", "G": "grass", "P": "plain", "W": "river_water", "T": "tree", "H": "stone_hill"},
		"rows": rows,
	}


func _river_center_y(x: int) -> float:
	var slow = (_value_noise(float(x) * 0.018, 0.0) - 0.5) * 110.0
	var fast = sin(float(x) * 0.037 + float(seed_value % 97)) * 12.0
	return slow + fast


func _fbm(x: float, y: float, octaves: int) -> float:
	var total = 0.0
	var amplitude = 0.5
	var frequency = 1.0
	var normalization = 0.0
	for _i in range(octaves):
		total += _value_noise(x * frequency, y * frequency) * amplitude
		normalization += amplitude
		amplitude *= 0.5
		frequency *= 2.0
	return total / max(normalization, 0.0001)


func _value_noise(x: float, y: float) -> float:
	var x0 = int(floor(x))
	var y0 = int(floor(y))
	var x1 = x0 + 1
	var y1 = y0 + 1
	var sx = _smoothstep(x - float(x0))
	var sy = _smoothstep(y - float(y0))
	var n00 = _hash_to_unit(x0, y0)
	var n10 = _hash_to_unit(x1, y0)
	var n01 = _hash_to_unit(x0, y1)
	var n11 = _hash_to_unit(x1, y1)
	var ix0 = lerp(n00, n10, sx)
	var ix1 = lerp(n01, n11, sx)
	return lerp(ix0, ix1, sy)


func _smoothstep(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


func _hash_to_unit(x: int, y: int) -> float:
	var raw = sin(float(x) * 127.1 + float(y) * 311.7 + float(seed_value) * 74.7) * 43758.5453123
	return raw - floor(raw)
