class_name PixelActorView
extends Node2D

var is_ai = false
var mood = "calm"
var direction = "down"

var body_color = Color("2f7dd1")
var accent_color = Color("f0c36a")
var hair_color = Color("2b1b15")
var skin_color = Color("f2b98b")
var shadow_color = Color(0.0, 0.0, 0.0, 0.28)

var _sprite_texture: Texture2D
var _sprite_columns = 12
var _sprite_rows = 1
var _sprite_frames_per_direction = 3
var _sprite_direction_rows = {"down": 0, "right": 1, "left": 2, "up": 3}
var _sprite_direction_frames = {"down": 0, "right": 3, "left": 6, "up": 9}
var _sprite_frame_width = 0.0
var _sprite_frame_height = 0.0
var _sprite_draw_size = Vector2(42, 67)
var _sprite_bottom_y = 12.0
var _sprite_fps = 6.0
var _sprite_idle_frame = 0
var _sprite_walk_sequence = []
var _sprite_frame = 0
var _sprite_time = 0.0
var _is_moving = false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_ai_skin() -> void:
	is_ai = true
	body_color = Color("854fd8")
	accent_color = Color("7ee0d2")
	hair_color = Color("433052")
	skin_color = Color("eec6aa")
	queue_redraw()


func set_player_skin() -> void:
	is_ai = false
	body_color = Color("2f7dd1")
	accent_color = Color("f0c36a")
	hair_color = Color("2b1b15")
	skin_color = Color("f2b98b")
	queue_redraw()


func set_sprite_sheet(config: Dictionary) -> void:
	var path = str(config.get("path", "")).strip_edges()
	if path.is_empty():
		_sprite_texture = null
		queue_redraw()
		return

	var loaded = load(path) if ResourceLoader.exists(path) else null
	if loaded is Texture2D:
		_sprite_texture = loaded
	else:
		var image = Image.new()
		if image.load(path) == OK:
			_sprite_texture = ImageTexture.create_from_image(image)
		else:
			_sprite_texture = null
			queue_redraw()
			return

	_sprite_columns = max(1, int(config.get("columns", 3)))
	_sprite_rows = max(1, int(config.get("rows", 4)))
	_sprite_frames_per_direction = max(1, int(config.get("frames_per_direction", _sprite_columns)))
	_sprite_fps = max(0.1, float(config.get("fps", 6.0)))
	_sprite_bottom_y = float(config.get("bottom_y", 12.0))
	_sprite_frame_width = max(0.0, float(config.get("frame_width", 0.0)))
	_sprite_frame_height = max(0.0, float(config.get("frame_height", 0.0)))

	var draw_size = config.get("draw_size", [42, 42])
	if typeof(draw_size) == TYPE_ARRAY and draw_size.size() >= 2:
		_sprite_draw_size = Vector2(float(draw_size[0]), float(draw_size[1]))
	elif typeof(draw_size) == TYPE_VECTOR2:
		_sprite_draw_size = draw_size

	var rows = config.get("direction_rows", {})
	if typeof(rows) == TYPE_DICTIONARY:
		_sprite_direction_rows = {
			"down": int(rows.get("down", 0)),
			"right": int(rows.get("right", 1)),
			"left": int(rows.get("left", 2)),
			"up": int(rows.get("up", 3)),
		}

	var frames = config.get("direction_frames", {})
	if typeof(frames) == TYPE_DICTIONARY and not frames.is_empty():
		_sprite_direction_frames = {
			"down": int(frames.get("down", 0)),
			"right": int(frames.get("right", 3)),
			"left": int(frames.get("left", 6)),
			"up": int(frames.get("up", 9)),
		}
	else:
		_sprite_direction_frames = {}
	var animation_frames = _animation_frame_count()
	_sprite_idle_frame = int(clamp(int(config.get("idle_frame", 0)), 0, animation_frames - 1))
	_sprite_walk_sequence = _normalized_frame_sequence(config.get("walk_sequence", []), animation_frames)
	_sprite_frame = _sprite_idle_frame
	_sprite_time = 0.0
	queue_redraw()


func set_moving(value: bool) -> void:
	if _is_moving == value:
		return
	_is_moving = value
	if _is_moving:
		_sprite_time = 0.0
		_sprite_frame = _walk_frame_at(0)
	else:
		_sprite_frame = _sprite_idle_frame
	queue_redraw()


func set_direction(value: String) -> void:
	if direction == value:
		return
	direction = value
	queue_redraw()


func set_mood(value: String) -> void:
	if mood == value:
		return
	mood = value
	queue_redraw()


func _process(delta: float) -> void:
	if _sprite_texture == null:
		return
	if _is_moving:
		_sprite_time += delta
		var next_frame = _walk_frame_at(int(floor(_sprite_time * _sprite_fps)))
		if next_frame != _sprite_frame:
			_sprite_frame = next_frame
			queue_redraw()
	elif _sprite_frame != _sprite_idle_frame:
		_sprite_frame = _sprite_idle_frame
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2(-7, 7), Vector2(14, 3)), shadow_color, true)
	if _sprite_texture != null:
		_draw_sprite_sheet_frame()
		return
	_draw_body()
	_draw_head()


func _draw_sprite_sheet_frame() -> void:
	var frame_width = _sprite_frame_width if _sprite_frame_width > 0.0 else float(_sprite_texture.get_width()) / float(_sprite_columns)
	var frame_height = _sprite_frame_height if _sprite_frame_height > 0.0 else float(_sprite_texture.get_height()) / float(_sprite_rows)
	var frame = int(clamp(_sprite_frame, 0, _animation_frame_count() - 1))
	var source: Rect2
	if not _sprite_direction_frames.is_empty():
		var absolute_frame = int(_sprite_direction_frames.get(direction, 0)) + frame
		var column = absolute_frame % _sprite_columns
		var row = int(clamp(floor(float(absolute_frame) / float(_sprite_columns)), 0, _sprite_rows - 1))
		source = Rect2(Vector2(column * frame_width, row * frame_height), Vector2(frame_width, frame_height))
	else:
		var row = int(clamp(int(_sprite_direction_rows.get(direction, 0)), 0, _sprite_rows - 1))
		source = Rect2(Vector2(frame * frame_width, row * frame_height), Vector2(frame_width, frame_height))
	var dest = Rect2(Vector2(-_sprite_draw_size.x * 0.5, _sprite_bottom_y - _sprite_draw_size.y), _sprite_draw_size)
	draw_texture_rect_region(_sprite_texture, dest, source)


func _animation_frame_count() -> int:
	return _sprite_frames_per_direction if not _sprite_direction_frames.is_empty() else _sprite_columns


func _walk_frame_at(step: int) -> int:
	if _sprite_walk_sequence.is_empty():
		return step % _animation_frame_count()
	return int(_sprite_walk_sequence[step % _sprite_walk_sequence.size()])


func _normalized_frame_sequence(sequence, frame_count: int) -> Array:
	var result = []
	if typeof(sequence) == TYPE_ARRAY:
		for value in sequence:
			var frame = int(value)
			if frame >= 0 and frame < frame_count:
				result.append(frame)
	elif typeof(sequence) == TYPE_STRING:
		var text = str(sequence).strip_edges()
		for index in range(text.length()):
			var frame = int(text.substr(index, 1)) - 1
			if frame >= 0 and frame < frame_count:
				result.append(frame)
	return result


func _draw_body() -> void:
	draw_rect(Rect2(Vector2(-5, -4), Vector2(10, 10)), body_color, true)
	draw_rect(Rect2(Vector2(-4, -2), Vector2(8, 2)), accent_color, true)
	draw_rect(Rect2(Vector2(-7, -3), Vector2(2, 7)), body_color.darkened(0.15), true)
	draw_rect(Rect2(Vector2(5, -3), Vector2(2, 7)), body_color.darkened(0.15), true)
	draw_rect(Rect2(Vector2(-4, 6), Vector2(3, 6)), Color("273447"), true)
	draw_rect(Rect2(Vector2(1, 6), Vector2(3, 6)), Color("273447"), true)


func _draw_head() -> void:
	draw_rect(Rect2(Vector2(-5, -15), Vector2(10, 10)), skin_color, true)
	draw_rect(Rect2(Vector2(-5, -16), Vector2(10, 3)), hair_color, true)

	if direction == "up":
		draw_rect(Rect2(Vector2(-5, -15), Vector2(10, 5)), hair_color, true)
		return

	var eye_color = Color("1b1f2a")
	if is_ai and mood == "happy":
		draw_rect(Rect2(Vector2(-3, -11), Vector2(2, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -11), Vector2(2, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(-2, -8), Vector2(4, 1)), Color("8f3945"), true)
	elif is_ai and mood == "worried":
		draw_rect(Rect2(Vector2(-3, -12), Vector2(2, 2)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -12), Vector2(2, 2)), eye_color, true)
		draw_rect(Rect2(Vector2(-2, -8), Vector2(4, 1)), Color("77515b"), true)
	elif is_ai and (mood == "angry" or mood == "annoyed"):
		draw_rect(Rect2(Vector2(-4, -12), Vector2(3, 2)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -12), Vector2(3, 2)), eye_color, true)
		draw_rect(Rect2(Vector2(-4, -13), Vector2(3, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -13), Vector2(3, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(-2, -8), Vector2(4, 1)), Color("6d1f2b"), true)
	elif is_ai and (mood == "disappointed" or mood == "sad"):
		draw_rect(Rect2(Vector2(-3, -11), Vector2(2, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -11), Vector2(2, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(-2, -8), Vector2(4, 1)), Color("4d5361"), true)
	elif is_ai and mood == "afraid":
		draw_rect(Rect2(Vector2(-3, -12), Vector2(2, 3)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -12), Vector2(2, 3)), eye_color, true)
		draw_rect(Rect2(Vector2(-2, -8), Vector2(4, 1)), Color("77515b"), true)
	elif is_ai and mood == "tired":
		draw_rect(Rect2(Vector2(-3, -11), Vector2(2, 1)), eye_color, true)
		draw_rect(Rect2(Vector2(1, -11), Vector2(2, 1)), eye_color, true)
	else:
		if direction == "left":
			draw_rect(Rect2(Vector2(-4, -11), Vector2(2, 2)), eye_color, true)
		elif direction == "right":
			draw_rect(Rect2(Vector2(2, -11), Vector2(2, 2)), eye_color, true)
		else:
			draw_rect(Rect2(Vector2(-3, -11), Vector2(2, 2)), eye_color, true)
			draw_rect(Rect2(Vector2(1, -11), Vector2(2, 2)), eye_color, true)

	if is_ai and mood == "curious":
		draw_rect(Rect2(Vector2(3, -16), Vector2(2, 2)), accent_color, true)
