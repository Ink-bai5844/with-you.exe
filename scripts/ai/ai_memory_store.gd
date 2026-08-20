class_name AIMemoryStore
extends Node

const AppPaths = preload("res://scripts/core/app_paths.gd")
const GameConfig = preload("res://scripts/config/game_config.gd")

const RECENT_FILE_NAME = "ai_memory_recent.csv"
const HISTORY_FILE_NAME = "ai_memory_history.csv"
const META_FILE_NAME = "ai_memory_meta.csv"
const RECENT_TEMP_FILE_NAME = "ai_memory_recent.tmp"
const HISTORY_TEMP_FILE_NAME = "ai_memory_history.tmp"
const META_TEMP_FILE_NAME = "ai_memory_meta.tmp"
const LEGACY_JSON_FILE_NAME = "ai_memory.json"
const LEGACY_USER_JSON_PATH = "user://ai_memory.json"
const MAX_SUMMARY_LENGTH = 240

const RECENT_HEADERS = [
	"kind",
	"game_minutes",
	"summary",
	"trigger",
	"activation_source",
	"is_player_initiated",
	"is_automatic_perception",
	"is_ai_action_event",
	"should_consider_reply",
	"player_messages",
	"ai_events",
	"payload_game_minutes",
	"game_time",
	"system_time",
	"player_tile_x",
	"player_tile_y",
	"ai_tile_x",
	"ai_tile_y",
	"ai_mood",
	"ai_dialogue",
	"ai_thought",
	"ai_follow_enabled",
	"ai_set_follow",
	"ai_action_type",
	"ai_action_target",
	"ai_action_tile",
	"ai_action_raw",
	"memory_ids",
]
const HISTORY_HEADERS = ["id", "priority", "created_game_minutes", "last_seen_game_minutes", "source", "summary"]
const META_HEADERS = ["key", "value"]

var recent_limit = GameConfig.RECENT_HISTORY_LIMIT
var recent_history: Array = []
var historical_memories: Array = []
var next_id = 1
var recent_path = ""
var history_path = ""
var meta_path = ""
var recent_temp_path = ""
var history_temp_path = ""
var meta_temp_path = ""
var legacy_json_path = ""
var storage_dir = ""
var _dirty = false
var _save_delay = 0.0


func _ready() -> void:
	clear_memory()


func _process(delta: float) -> void:
	if not _dirty:
		return
	_save_delay -= delta
	if _save_delay <= 0.0:
		save_memory()


func _mark_memory_dirty() -> void:
	_dirty = true
	_save_delay = GameConfig.MEMORY_SAVE_DEBOUNCE_SECONDS


func set_storage_dir(new_storage_dir: String, load_existing = true) -> void:
	storage_dir = new_storage_dir
	DirAccess.make_dir_recursive_absolute(storage_dir)
	_reset_paths()
	if load_existing:
		load_memory()
	else:
		clear_memory()
		save_memory()


func clear_memory() -> void:
	recent_history = []
	historical_memories = []
	next_id = 1


func add_recent(summary: String, kind: String, game_minutes: float, payload = {}) -> void:
	recent_history.append({
		"kind": kind,
		"summary": summary.left(MAX_SUMMARY_LENGTH),
		"game_minutes": game_minutes,
		"payload": _sanitize_recent_payload(payload),
	})
	while recent_history.size() > recent_limit:
		recent_history.pop_front()
	_mark_memory_dirty()


func add_memory(summary: String, priority: int, game_minutes: float, source = "ai") -> int:
	var id = next_id
	next_id += 1
	historical_memories.append({
		"id": id,
		"summary": summary.left(MAX_SUMMARY_LENGTH),
		"priority": int(clamp(priority, 1, 9)),
		"created_game_minutes": game_minutes,
		"last_seen_game_minutes": game_minutes,
		"source": source,
	})
	_mark_memory_dirty()
	return id


func update_priority(id: int, priority: int) -> bool:
	for memory in historical_memories:
		if int(memory.get("id", -1)) == id:
			memory["priority"] = int(clamp(priority, 1, 9))
			_mark_memory_dirty()
			return true
	return false


func delete_memory(id: int, flush = true) -> bool:
	for index in range(historical_memories.size()):
		if int(historical_memories[index].get("id", -1)) == id:
			historical_memories.remove_at(index)
			if flush:
				_mark_memory_dirty()
			return true
	return false


func recall(count: int, now_game_minutes: float) -> Array:
	var scored = []
	for memory in historical_memories:
		var age = max(0.0, now_game_minutes - float(memory.get("created_game_minutes", now_game_minutes)))
		var priority = int(memory.get("priority", 1))
		var score = float(priority) * 10000.0 - age * 0.1 + randf() * float(priority + 1)
		scored.append({"score": score, "memory": memory})

	scored.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	var result = []
	for item in scored.slice(0, min(count, scored.size())):
		item["memory"]["last_seen_game_minutes"] = now_game_minutes
		var memory_copy = item["memory"].duplicate(true)
		result.append(memory_copy)
	if not result.is_empty():
		_mark_memory_dirty()
	return result


func forget_low_priority_percent(percent: float, now_game_minutes: float) -> Array:
	var total = historical_memories.size()
	var delete_count = int(floor(float(total) * percent))
	if delete_count <= 0 and total >= GameConfig.FORGET_MIN_MEMORIES and percent > 0.0:
		delete_count = 1
	if delete_count <= 0:
		return []

	var sorted = historical_memories.duplicate(true)
	sorted.sort_custom(func(a, b):
		var pa = int(a.get("priority", 1))
		var pb = int(b.get("priority", 1))
		if pa != pb:
			return pa < pb
		var age_a = now_game_minutes - float(a.get("created_game_minutes", now_game_minutes))
		var age_b = now_game_minutes - float(b.get("created_game_minutes", now_game_minutes))
		return age_a > age_b
	)

	var deleted = []
	for item in sorted.slice(0, delete_count):
		var id = int(item.get("id", -1))
		if delete_memory(id, false):
			deleted.append(id)
	if not deleted.is_empty():
		_mark_memory_dirty()
	return deleted


func apply_ai_memory_ops(ops: Dictionary, game_minutes: float) -> void:
	for item in ops.get("add", []):
		var summary = str(item.get("summary", "")).strip_edges()
		if not summary.is_empty():
			add_memory(summary, int(item.get("priority", 3)), game_minutes, "ai")

	for item in ops.get("update_priority", []):
		update_priority(int(item.get("id", -1)), int(item.get("priority", 3)))

	for id in ops.get("delete", []):
		delete_memory(int(id), false)
	_mark_memory_dirty()


func snapshot() -> Dictionary:
	return {
		"recent_limit": recent_limit,
		"recent_history": recent_history_for_prompt(),
		"historical_memory_count": historical_memories.size(),
		"next_id": next_id,
		"storage": {
			"recent_csv": recent_path,
			"history_csv": history_path,
			"meta_csv": meta_path,
		},
	}


func recent_history_for_prompt() -> Array:
	var result = []
	for entry in recent_history:
		result.append({
			"kind": str(entry.get("kind", "interaction")),
			"summary": str(entry.get("summary", "")).left(MAX_SUMMARY_LENGTH),
			"game_minutes": float(entry.get("game_minutes", 0.0)),
		})
	return result


func save_memory() -> void:
	_ensure_paths()
	_save_recent_csv()
	_save_history_csv()
	_save_meta_csv()
	_dirty = false
	_save_delay = 0.0


func load_memory() -> void:
	_ensure_paths()
	recent_history = []
	historical_memories = []
	next_id = 1

	if FileAccess.file_exists(recent_path) or FileAccess.file_exists(history_path) or FileAccess.file_exists(meta_path):
		_load_recent_csv()
		_load_history_csv()
		_load_meta_csv()
		_adjust_next_id()
		while recent_history.size() > recent_limit:
			recent_history.pop_front()
		save_memory()
		return

	if _load_legacy_json():
		_adjust_next_id()
		while recent_history.size() > recent_limit:
			recent_history.pop_front()
		save_memory()


func _save_recent_csv() -> void:
	var rows = []
	for entry in recent_history:
		rows.append(_recent_to_csv_row(entry))
	_write_csv_file(recent_path, recent_temp_path, RECENT_HEADERS, rows)


func _save_history_csv() -> void:
	var rows = []
	for memory in historical_memories:
		rows.append([
			str(int(memory.get("id", -1))),
			str(int(memory.get("priority", 1))),
			_minute_cell(memory.get("created_game_minutes", 0.0)),
			_minute_cell(memory.get("last_seen_game_minutes", 0.0)),
			_single_line(memory.get("source", "ai")),
			_single_line(str(memory.get("summary", "")).left(MAX_SUMMARY_LENGTH)),
		])
	_write_csv_file(history_path, history_temp_path, HISTORY_HEADERS, rows)


func _save_meta_csv() -> void:
	_write_csv_file(meta_path, meta_temp_path, META_HEADERS, [["next_id", str(next_id)]])


func _load_recent_csv() -> void:
	var rows = _read_csv_rows(recent_path)
	if rows.size() <= 1:
		return
	var headers = rows[0]
	for index in range(1, rows.size()):
		var data = _csv_row_to_dictionary(headers, rows[index])
		var summary = str(data.get("summary", "")).left(MAX_SUMMARY_LENGTH)
		if summary.is_empty() and str(data.get("kind", "")).is_empty():
			continue
		recent_history.append(_recent_from_csv_data(data))


func _load_history_csv() -> void:
	var rows = _read_csv_rows(history_path)
	if rows.size() <= 1:
		return
	var headers = rows[0]
	for index in range(1, rows.size()):
		var data = _csv_row_to_dictionary(headers, rows[index])
		var id = int(data.get("id", "0"))
		if id <= 0:
			continue
		historical_memories.append({
			"id": id,
			"summary": str(data.get("summary", "")).left(MAX_SUMMARY_LENGTH),
			"priority": int(clamp(int(data.get("priority", "1")), 1, 9)),
			"created_game_minutes": _float_from_text(data.get("created_game_minutes", "0")),
			"last_seen_game_minutes": _float_from_text(data.get("last_seen_game_minutes", "0")),
			"source": str(data.get("source", "ai")),
		})


func _load_meta_csv() -> void:
	var rows = _read_csv_rows(meta_path)
	if rows.size() <= 1:
		return
	var headers = rows[0]
	for index in range(1, rows.size()):
		var data = _csv_row_to_dictionary(headers, rows[index])
		if str(data.get("key", "")) == "next_id":
			next_id = max(1, int(data.get("value", "1")))


func _load_legacy_json() -> bool:
	for path in [legacy_json_path, LEGACY_USER_JSON_PATH]:
		if FileAccess.file_exists(path) and _load_legacy_json_file(path):
			return true
	return false


func _load_legacy_json_file(path: String) -> bool:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text = file.get_as_text()
	if text.strip_edges().is_empty():
		return false

	var json = JSON.new()
	var error = json.parse(text)
	if error != OK:
		_backup_corrupt_file(path)
		return false

	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return false

	for entry in parsed.get("recent_history", []):
		if typeof(entry) == TYPE_DICTIONARY:
			recent_history.append({
				"kind": str(entry.get("kind", "interaction")),
				"summary": str(entry.get("summary", "")).left(MAX_SUMMARY_LENGTH),
				"game_minutes": float(entry.get("game_minutes", 0.0)),
				"payload": _sanitize_recent_payload(entry.get("payload", {})),
			})

	for memory in parsed.get("historical_memories", []):
		if typeof(memory) == TYPE_DICTIONARY:
			historical_memories.append({
				"id": int(memory.get("id", next_id)),
				"summary": str(memory.get("summary", "")).left(MAX_SUMMARY_LENGTH),
				"priority": int(clamp(int(memory.get("priority", 1)), 1, 9)),
				"created_game_minutes": float(memory.get("created_game_minutes", 0.0)),
				"last_seen_game_minutes": float(memory.get("last_seen_game_minutes", 0.0)),
				"source": str(memory.get("source", "ai")),
			})
	next_id = int(parsed.get("next_id", 1))
	return true


func _recent_to_csv_row(entry: Dictionary) -> Array:
	var payload = _sanitize_recent_payload(entry.get("payload", {}))
	var activation: Dictionary = payload.get("activation", {})
	var game_time: Dictionary = payload.get("game_time", {})
	var player_tile = _tile_from_value(payload.get("player_tile", []))
	var ai_tile = _tile_from_value(payload.get("ai_tile", []))
	var action = payload.get("ai_action", {})
	if typeof(action) != TYPE_DICTIONARY:
		action = {}

	return [
		_single_line(entry.get("kind", "interaction")),
		_minute_cell(entry.get("game_minutes", 0.0)),
		_single_line(str(entry.get("summary", "")).left(MAX_SUMMARY_LENGTH)),
		_single_line(payload.get("trigger", "")),
		_single_line(activation.get("source", "")),
		_bool_cell(activation.get("is_player_initiated", false)),
		_bool_cell(activation.get("is_automatic_perception", false)),
		_bool_cell(activation.get("is_ai_action_event", false)),
		_bool_cell(activation.get("should_consider_reply", false)),
		_join_string_array(payload.get("player_messages", [])),
		_events_to_compact_text(payload.get("ai_events", [])),
		_minute_cell(game_time.get("game_minutes", 0.0)),
		_single_line(game_time.get("game_time", "")),
		_single_line(game_time.get("system_time", "")),
		str(player_tile.x),
		str(player_tile.y),
		str(ai_tile.x),
		str(ai_tile.y),
		_single_line(payload.get("ai_mood", "calm")),
		_single_line(payload.get("ai_dialogue", "")),
		_single_line(payload.get("ai_thought", "")),
		_bool_cell(payload.get("ai_follow_enabled", false)),
		str(int(payload.get("ai_set_follow", -1))),
		_single_line(action.get("type", "")),
		_single_line(action.get("target", action.get("target_kind", action.get("tile_kind", "")))),
		_tile_to_text(action.get("tile", action.get("target_tile", action.get("found_tile", [])))),
		_compact_json(action),
		_join_int_array(payload.get("memory_ids", [])),
	]


func _recent_from_csv_data(data: Dictionary) -> Dictionary:
	var payload_game_time = {
		"game_minutes": _float_from_text(data.get("payload_game_minutes", "0")),
		"game_time": str(data.get("game_time", "")),
		"system_time": str(data.get("system_time", "")),
	}
	var payload = {
		"trigger": str(data.get("trigger", "")),
		"activation": {
			"trigger": str(data.get("trigger", "")),
			"source": str(data.get("activation_source", "")),
			"is_player_initiated": _bool_from_text(data.get("is_player_initiated", "")),
			"is_automatic_perception": _bool_from_text(data.get("is_automatic_perception", "")),
			"is_ai_action_event": _bool_from_text(data.get("is_ai_action_event", "")),
			"should_consider_reply": _bool_from_text(data.get("should_consider_reply", "")),
		},
		"player_messages": _split_string_array(data.get("player_messages", "")),
		"ai_events": _events_from_compact_text(data.get("ai_events", "")),
		"game_time": payload_game_time,
		"player_tile": _tile_array_from_columns(data, "player_tile"),
		"ai_tile": _tile_array_from_columns(data, "ai_tile"),
		"ai_mood": str(data.get("ai_mood", "calm")),
		"ai_dialogue": str(data.get("ai_dialogue", "")),
		"ai_thought": str(data.get("ai_thought", "")),
		"ai_follow_enabled": _bool_from_text(data.get("ai_follow_enabled", "")),
		"ai_set_follow": int(data.get("ai_set_follow", "-1")),
		"ai_action": _action_from_csv_data(data),
		"memory_ids": _int_array_from_text(data.get("memory_ids", "")),
	}
	return {
		"kind": str(data.get("kind", "interaction")),
		"summary": str(data.get("summary", "")).left(MAX_SUMMARY_LENGTH),
		"game_minutes": _float_from_text(data.get("game_minutes", "0")),
		"payload": _sanitize_recent_payload(payload),
	}


func _action_from_csv_data(data: Dictionary) -> Dictionary:
	var raw_action = _parse_json_dictionary(data.get("ai_action_raw", ""))
	if not raw_action.is_empty():
		return raw_action

	var action_type = str(data.get("ai_action_type", "")).strip_edges()
	if action_type.is_empty():
		return {}
	var action = {"type": action_type}
	var target = str(data.get("ai_action_target", "")).strip_edges()
	if not target.is_empty():
		action["target"] = target
	var tile = _tile_from_text(data.get("ai_action_tile", ""))
	if not tile.is_empty():
		action["tile"] = tile
	return action


func _write_csv_file(path: String, temp_path: String, headers: Array, rows: Array) -> void:
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return
	_write_csv_lines(file, headers, rows)
	file.flush()
	file = null

	if _replace_file(temp_path, path) != OK:
		var direct_file = FileAccess.open(path, FileAccess.WRITE)
		if direct_file == null:
			return
		_write_csv_lines(direct_file, headers, rows)
		direct_file.flush()
		direct_file = null
		DirAccess.remove_absolute(temp_path)


func _write_csv_lines(file: FileAccess, headers: Array, rows: Array) -> void:
	_store_csv_row(file, headers)
	for row in rows:
		_store_csv_row(file, row)


func _store_csv_row(file: FileAccess, values: Array) -> void:
	var packed = PackedStringArray()
	for value in values:
		packed.append(str(value))
	file.store_csv_line(packed)


func _read_csv_rows(path: String) -> Array:
	var rows = []
	if not FileAccess.file_exists(path):
		return rows

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return rows

	while not file.eof_reached():
		var row = Array(file.get_csv_line())
		if row.is_empty():
			continue
		if row.size() == 1 and str(row[0]).strip_edges().is_empty():
			continue
		rows.append(row)
	return rows


func _csv_row_to_dictionary(headers: Array, row: Array) -> Dictionary:
	var result = {}
	for index in range(headers.size()):
		var key = str(headers[index])
		if index == 0:
			key = key.trim_prefix("\ufeff")
		result[key] = str(row[index]) if index < row.size() else ""
	return result


func _replace_file(temp_path: String, path: String) -> int:
	if FileAccess.file_exists(path):
		var remove_error = DirAccess.remove_absolute(path)
		if remove_error != OK:
			return remove_error
	return DirAccess.rename_absolute(temp_path, path)


func _adjust_next_id() -> void:
	var minimum_next_id = 1
	for memory in historical_memories:
		minimum_next_id = max(minimum_next_id, int(memory.get("id", 0)) + 1)
	next_id = max(next_id, minimum_next_id)


func _sanitize_recent_payload(payload) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return {}

	var source = payload
	if typeof(payload.get("snapshot", null)) == TYPE_DICTIONARY:
		source = payload["snapshot"]

	var response = payload.get("response", {})
	if typeof(response) != TYPE_DICTIONARY:
		response = {}

	return {
		"trigger": str(source.get("trigger", "")),
		"activation": _sanitize_activation(source.get("activation", {})),
		"player_messages": _limited_string_array(source.get("player_messages", []), 5, 160),
		"ai_events": _limited_event_array(source.get("ai_events", []), 5),
		"game_time": source.get("game_time", {}),
		"player_tile": source.get("player_tile", []),
		"ai_tile": source.get("ai_tile", []),
		"ai_mood": str(response.get("mood", source.get("ai_mood", "calm"))),
		"ai_dialogue": str(response.get("dialogue", source.get("ai_dialogue", ""))).left(240),
		"ai_thought": str(response.get("thought", source.get("ai_thought", ""))).left(240),
		"ai_follow_enabled": bool(source.get("ai_follow_enabled", false)),
		"ai_set_follow": int(response.get("set_follow", source.get("ai_set_follow", -1))),
		"ai_action": response.get("action", source.get("ai_action", {})),
		"memory_ids": source.get("memory_ids", []),
	}


func _sanitize_activation(value) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return {
		"trigger": str(value.get("trigger", "")),
		"source": str(value.get("source", "")),
		"is_player_initiated": bool(value.get("is_player_initiated", false)),
		"is_automatic_perception": bool(value.get("is_automatic_perception", false)),
		"is_ai_action_event": bool(value.get("is_ai_action_event", false)),
		"player_message_count": int(value.get("player_message_count", 0)),
		"ai_event_count": int(value.get("ai_event_count", 0)),
		"should_consider_reply": bool(value.get("should_consider_reply", false)),
		"reply_policy": str(value.get("reply_policy", "")).left(240),
	}


func _limited_string_array(value, max_count: int, max_length: int) -> Array:
	var result = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value.slice(0, min(max_count, value.size())):
		result.append(str(item).left(max_length))
	return result


func _limited_event_array(value, max_count: int) -> Array:
	var result = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value.slice(0, min(max_count, value.size())):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		result.append({
			"event_type": str(item.get("event_type", "")),
			"action_type": str(item.get("action_type", "")),
			"target": str(item.get("target", "")),
			"tile_kind": str(item.get("tile_kind", "")),
			"status": str(item.get("status", "")),
			"found_tile": item.get("found_tile", []),
			"target_tile": item.get("target_tile", []),
			"ai_tile": item.get("ai_tile", []),
		})
	return result


func _join_string_array(value) -> String:
	var items = []
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			items.append(_single_line(item))
	return " | ".join(items)


func _split_string_array(value) -> Array:
	var text = str(value)
	if text.strip_edges().is_empty():
		return []
	var result = []
	for item in text.split(" | ", false):
		result.append(str(item))
	return result


func _join_int_array(value) -> String:
	var items = []
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			items.append(str(int(item)))
	return ";".join(items)


func _int_array_from_text(value) -> Array:
	var text = str(value)
	if text.strip_edges().is_empty():
		return []
	var result = []
	for item in text.split(";", false):
		result.append(int(item))
	return result


func _events_to_compact_text(value) -> String:
	var items = []
	if typeof(value) != TYPE_ARRAY:
		return ""
	for item in value:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		items.append("|".join([
			_compact_piece(item.get("event_type", "")),
			_compact_piece(item.get("action_type", "")),
			_compact_piece(item.get("target", "")),
			_compact_piece(item.get("tile_kind", "")),
			_compact_piece(item.get("status", "")),
			_tile_to_text(item.get("found_tile", [])),
			_tile_to_text(item.get("target_tile", [])),
			_tile_to_text(item.get("ai_tile", [])),
		]))
	return " ; ".join(items)


func _events_from_compact_text(value) -> Array:
	var text = str(value)
	if text.strip_edges().is_empty():
		return []
	var result = []
	for item in text.split(" ; ", false):
		var parts = item.split("|", true)
		result.append({
			"event_type": str(parts[0]) if parts.size() > 0 else "",
			"action_type": str(parts[1]) if parts.size() > 1 else "",
			"target": str(parts[2]) if parts.size() > 2 else "",
			"tile_kind": str(parts[3]) if parts.size() > 3 else "",
			"status": str(parts[4]) if parts.size() > 4 else "",
			"found_tile": _tile_from_text(parts[5]) if parts.size() > 5 else [],
			"target_tile": _tile_from_text(parts[6]) if parts.size() > 6 else [],
			"ai_tile": _tile_from_text(parts[7]) if parts.size() > 7 else [],
		})
	return result


func _tile_to_text(value) -> String:
	if typeof(value) == TYPE_VECTOR2I:
		return "%d:%d" % [value.x, value.y]
	if typeof(value) == TYPE_VECTOR2:
		return "%d:%d" % [int(value.x), int(value.y)]
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return "%d:%d" % [int(value[0]), int(value[1])]
	return ""


func _tile_from_text(value) -> Array:
	var text = str(value)
	if text.strip_edges().is_empty():
		return []
	var parts = text.split(":", false)
	if parts.size() < 2:
		return []
	return [int(parts[0]), int(parts[1])]


func _tile_from_value(value) -> Vector2i:
	if typeof(value) == TYPE_VECTOR2I:
		return value
	if typeof(value) == TYPE_VECTOR2:
		return Vector2i(int(value.x), int(value.y))
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


func _tile_array_from_columns(data: Dictionary, prefix: String) -> Array:
	var x_text = str(data.get(prefix + "_x", ""))
	var y_text = str(data.get(prefix + "_y", ""))
	if x_text.strip_edges().is_empty() or y_text.strip_edges().is_empty():
		return []
	return [int(x_text), int(y_text)]


func _parse_json_dictionary(value) -> Dictionary:
	var text = str(value)
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _compact_json(value) -> String:
	if typeof(value) != TYPE_DICTIONARY or value.is_empty():
		return ""
	return JSON.stringify(value)


func _bool_cell(value) -> String:
	return "1" if bool(value) else "0"


func _bool_from_text(value) -> bool:
	var text = str(value).strip_edges().to_lower()
	return text == "1" or text == "true" or text == "yes" or text == "on"


func _minute_cell(value) -> String:
	return str(int(round(float(value))))


func _float_from_text(value) -> float:
	var text = str(value).strip_edges()
	return 0.0 if text.is_empty() else text.to_float()


func _single_line(value) -> String:
	return str(value).replace("\r", " ").replace("\n", " ").strip_edges()


func _compact_piece(value) -> String:
	return _single_line(value).replace("|", "/").replace(";", ",")


func _backup_corrupt_file(path: String) -> void:
	var absolute_path = ProjectSettings.globalize_path(path) if path.begins_with("user://") or path.begins_with("res://") else path
	var backup_path = "%s.corrupt-%s" % [absolute_path, Time.get_unix_time_from_system()]
	DirAccess.rename_absolute(absolute_path, backup_path)


func _ensure_paths() -> void:
	if storage_dir.is_empty():
		storage_dir = AppPaths.user_data_dir()
	DirAccess.make_dir_recursive_absolute(storage_dir)
	if recent_path.is_empty():
		recent_path = storage_dir.path_join(RECENT_FILE_NAME)
	if history_path.is_empty():
		history_path = storage_dir.path_join(HISTORY_FILE_NAME)
	if meta_path.is_empty():
		meta_path = storage_dir.path_join(META_FILE_NAME)
	if recent_temp_path.is_empty():
		recent_temp_path = storage_dir.path_join(RECENT_TEMP_FILE_NAME)
	if history_temp_path.is_empty():
		history_temp_path = storage_dir.path_join(HISTORY_TEMP_FILE_NAME)
	if meta_temp_path.is_empty():
		meta_temp_path = storage_dir.path_join(META_TEMP_FILE_NAME)
	if legacy_json_path.is_empty():
		legacy_json_path = storage_dir.path_join(LEGACY_JSON_FILE_NAME)


func _reset_paths() -> void:
	recent_path = ""
	history_path = ""
	meta_path = ""
	recent_temp_path = ""
	history_temp_path = ""
	meta_temp_path = ""
	legacy_json_path = ""
