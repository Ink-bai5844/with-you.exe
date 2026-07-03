class_name PortraitView
extends Control

var is_ai = true
var mood = "calm"
var portrait_dir = ""
var _portrait_texture: Texture2D
var _portrait_texture_key = ""


func set_character(new_is_ai: bool, new_mood: String) -> void:
	is_ai = new_is_ai
	mood = new_mood
	queue_redraw()


func set_portrait_dir(path: String) -> void:
	var normalized = path.strip_edges().trim_suffix("/")
	if portrait_dir == normalized:
		return
	portrait_dir = normalized
	_portrait_texture = null
	_portrait_texture_key = ""
	queue_redraw()


func _draw() -> void:
	if _draw_portrait_texture():
		return

	var bg = Color("1d2430") if is_ai else Color("17263a")
	var skin = Color("eec6aa") if is_ai else Color("f2b98b")
	var hair = Color("433052") if is_ai else Color("2b1b15")
	var accent = Color("7ee0d2") if is_ai else Color("f0c36a")
	draw_rect(Rect2(Vector2.ZERO, size), bg, true)
	var scale_factor = min(size.x, size.y) / 32.0
	var origin = (size - Vector2(32, 32) * scale_factor) * 0.5
	_draw_px(Rect2(7, 8, 18, 18), skin, origin, scale_factor)
	_draw_px(Rect2(7, 6, 18, 6), hair, origin, scale_factor)
	_draw_px(Rect2(5, 15, 3, 7), hair, origin, scale_factor)
	_draw_px(Rect2(24, 15, 3, 7), hair, origin, scale_factor)

	if mood == "happy":
		_draw_px(Rect2(11, 17, 4, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 17, 4, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(13, 22, 6, 1), Color("9e3d4d"), origin, scale_factor)
	elif mood == "worried":
		_draw_px(Rect2(11, 16, 4, 2), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 16, 4, 2), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(13, 23, 6, 1), Color("73515b"), origin, scale_factor)
	elif mood == "angry" or mood == "annoyed":
		_draw_px(Rect2(11, 16, 4, 2), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 16, 4, 2), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(10, 15, 5, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 15, 5, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(13, 23, 6, 1), Color("6d1f2b"), origin, scale_factor)
	elif mood == "disappointed" or mood == "sad":
		_draw_px(Rect2(11, 17, 4, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 17, 4, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(13, 23, 6, 1), Color("4d5361"), origin, scale_factor)
	elif mood == "afraid":
		_draw_px(Rect2(11, 16, 4, 3), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 16, 4, 3), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(13, 23, 6, 1), Color("73515b"), origin, scale_factor)
	elif mood == "tired":
		_draw_px(Rect2(11, 17, 4, 1), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(17, 17, 4, 1), Color("111820"), origin, scale_factor)
	else:
		_draw_px(Rect2(12, 16, 3, 3), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(18, 16, 3, 3), Color("111820"), origin, scale_factor)
		_draw_px(Rect2(14, 22, 5, 1), Color("8f3945"), origin, scale_factor)

	if is_ai:
		_draw_px(Rect2(23, 7, 3, 3), accent, origin, scale_factor)


func _draw_px(rect: Rect2, color: Color, origin: Vector2, scale_factor: float) -> void:
	draw_rect(Rect2(origin + rect.position * scale_factor, rect.size * scale_factor), color, true)


func _draw_portrait_texture() -> bool:
	var texture = _get_portrait_texture()
	if texture == null:
		return false
	draw_rect(Rect2(Vector2.ZERO, size), Color("1d2430") if is_ai else Color("17263a"), true)
	var texture_size = texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return false
	var scale_factor = min(size.x / texture_size.x, size.y / texture_size.y)
	var draw_size = texture_size * scale_factor
	var draw_position = (size - draw_size) * 0.5
	draw_texture_rect(texture, Rect2(draw_position, draw_size), false)
	return true


func _get_portrait_texture() -> Texture2D:
	if not is_ai or portrait_dir.is_empty():
		return null
	var key = "%s|%s" % [portrait_dir, mood]
	if _portrait_texture_key == key:
		return _portrait_texture
	_portrait_texture_key = key
	_portrait_texture = _load_mood_portrait(mood)
	if _portrait_texture == null and mood != "calm":
		_portrait_texture = _load_mood_portrait("calm")
	return _portrait_texture


func _load_mood_portrait(target_mood: String) -> Texture2D:
	for extension in ["png", "webp", "jpg", "jpeg"]:
		var path = "%s/%s.%s" % [portrait_dir, target_mood, extension]
		var texture = _load_texture(path)
		if texture != null:
			return texture
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
