class_name WorldRenderer
extends Node2D

const GameConfig = preload("res://scripts/config/game_config.gd")
const WorldGeneratorScript = preload("res://scripts/world/world_generator.gd")

const TILE_TEXTURE_DIR = "res://assets/tiles/terrain/default"

var generator = WorldGeneratorScript.new()
var tile_size = GameConfig.TILE_SIZE
var _tile_textures = {}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_seed(seed_value: int) -> void:
	generator = WorldGeneratorScript.new(seed_value)
	queue_redraw()


func get_seed() -> int:
	return int(generator.seed_value)


func get_save_data() -> Dictionary:
	return {"seed": get_seed()}


func apply_save_data(data: Dictionary) -> void:
	set_seed(int(data.get("seed", GameConfig.DEFAULT_WORLD_SEED)))


func world_to_tile(world_position: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_position.x / tile_size)), int(floor(world_position.y / tile_size)))


func tile_to_world(tile: Vector2i) -> Vector2:
	return Vector2(float(tile.x * tile_size), float(tile.y * tile_size))


func encode_area(center: Vector2i, radius: int) -> Dictionary:
	return generator.encode_area(center, radius)


func get_tile_kind(tile: Vector2i) -> String:
	return generator.get_tile_kind(tile)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var camera = get_viewport().get_camera_2d()
	var camera_position = Vector2.ZERO
	var camera_zoom = Vector2.ONE
	if camera != null:
		camera_position = camera.global_position
		camera_zoom = camera.zoom

	var view_size = get_viewport_rect().size / camera_zoom
	var center = world_to_tile(camera_position)
	var half_x = int(ceil(view_size.x / float(tile_size) * 0.5)) + 4
	var half_y = int(ceil(view_size.y / float(tile_size) * 0.5)) + 4

	for y in range(center.y - half_y, center.y + half_y + 1):
		for x in range(center.x - half_x, center.x + half_x + 1):
			var tile = Vector2i(x, y)
			var kind = generator.get_tile_kind(tile)
			var color = generator.tile_color(kind)
			var rect = Rect2(tile_to_world(tile), Vector2(tile_size, tile_size))
			var texture = _tile_texture(kind)
			if texture != null:
				draw_texture_rect(texture, rect, false)
			else:
				draw_rect(rect, color, true)

				if kind == WorldGeneratorScript.TILE_GRASS and _detail_dot(tile):
					draw_rect(Rect2(rect.position + Vector2(6, 4), Vector2(2, 2)), Color("2e6c36"), true)
				elif kind == WorldGeneratorScript.TILE_PLAIN and _detail_dot(tile):
					draw_rect(Rect2(rect.position + Vector2(3, 10), Vector2(3, 1)), Color("678e50"), true)

	var city_rect = Rect2(
		Vector2(-GameConfig.CITY_HALF_SIZE * tile_size, -GameConfig.CITY_HALF_SIZE * tile_size),
		Vector2(GameConfig.CITY_SIZE * tile_size, GameConfig.CITY_SIZE * tile_size)
	)
	draw_rect(city_rect, Color("111820"), false, 3.0)
	draw_line(Vector2(city_rect.position.x, 0.0), Vector2(city_rect.position.x + city_rect.size.x, 0.0), Color("aeb8c2"), 1.0)
	draw_line(Vector2(0.0, city_rect.position.y), Vector2(0.0, city_rect.position.y + city_rect.size.y), Color("aeb8c2"), 1.0)


func _detail_dot(tile: Vector2i) -> bool:
	var raw = sin(float(tile.x * 17 + tile.y * 43 + generator.seed_value) * 0.73) * 10000.0
	return raw - floor(raw) > 0.72


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
