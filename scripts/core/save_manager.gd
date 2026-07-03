class_name SaveManager
extends RefCounted

const AppPaths = preload("res://scripts/core/app_paths.gd")

const SAVE_VERSION = 1
const SAVES_DIR_NAME = "saves"
const SAVE_FILE_NAME = "save.json"
const MEMORY_DIR_NAME = "memory"
const LEGACY_MEMORY_FILES = [
	"ai_memory_recent.csv",
	"ai_memory_history.csv",
	"ai_memory_meta.csv",
	"ai_memory.json",
]


static func saves_dir() -> String:
	return AppPaths.user_data_subdir(SAVES_DIR_NAME)


static func save_dir(save_id: String) -> String:
	var dir_path = saves_dir().path_join(_safe_id(save_id))
	DirAccess.make_dir_recursive_absolute(dir_path)
	return dir_path


static func memory_dir(save_id: String) -> String:
	var dir_path = save_dir(save_id).path_join(MEMORY_DIR_NAME)
	DirAccess.make_dir_recursive_absolute(dir_path)
	return dir_path


static func save_file_path(save_id: String) -> String:
	return save_dir(save_id).path_join(SAVE_FILE_NAME)


static func create_save_id(save_name: String) -> String:
	var base = _safe_id(save_name)
	if base.is_empty():
		base = "save"
	var stamp = Time.get_datetime_string_from_system(false, true).replace("-", "").replace(":", "").replace(" ", "_")
	var candidate = "%s_%s" % [base, stamp]
	var unique = candidate
	var suffix = 2
	while FileAccess.file_exists(save_file_path(unique)):
		unique = "%s_%d" % [candidate, suffix]
		suffix += 1
	return unique


static func list_saves() -> Array:
	var result = []
	var dir = DirAccess.open(saves_dir())
	if dir == null:
		return result

	dir.list_dir_begin()
	var entry = dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var data = load_save(entry)
			if not data.is_empty():
				result.append(summary_from_data(data))
		entry = dir.get_next()
	dir.list_dir_end()

	result.sort_custom(func(a, b):
		return str(a.get("updated_system_time", "")) > str(b.get("updated_system_time", ""))
	)
	return result


static func has_global_memory_files() -> bool:
	for file_name in LEGACY_MEMORY_FILES:
		if FileAccess.file_exists(AppPaths.user_data_file(file_name)):
			return true
	return false


static func migrate_global_memory_to_save(save_id: String, save_data: Dictionary, move_files = true) -> bool:
	if not has_global_memory_files():
		return false

	var target_save_id = _safe_id(save_id)
	if target_save_id.is_empty():
		return false

	var target_memory_dir = memory_dir(target_save_id)
	var copied_any = false
	for file_name in LEGACY_MEMORY_FILES:
		var source_path = AppPaths.user_data_file(file_name)
		if not FileAccess.file_exists(source_path):
			continue
		var target_path = target_memory_dir.path_join(file_name)
		if _copy_text_file(source_path, target_path):
			copied_any = true

	if not copied_any:
		return false

	var output = save_data.duplicate(true)
	output["save_id"] = target_save_id
	if not write_save(target_save_id, output):
		return false

	if move_files:
		for file_name in LEGACY_MEMORY_FILES:
			var source_path = AppPaths.user_data_file(file_name)
			if FileAccess.file_exists(source_path):
				DirAccess.remove_absolute(source_path)
	return true


static func load_save(save_id: String) -> Dictionary:
	var path = save_file_path(save_id)
	if not FileAccess.file_exists(path):
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	parsed["save_id"] = str(parsed.get("save_id", save_id))
	return parsed


static func write_save(save_id: String, data: Dictionary) -> bool:
	var existing = load_save(save_id)
	var output = data.duplicate(true)
	output["version"] = SAVE_VERSION
	output["save_id"] = _safe_id(save_id)
	if not output.has("created_system_time"):
		output["created_system_time"] = existing.get("created_system_time", Time.get_datetime_string_from_system(false, true))
	output["updated_system_time"] = Time.get_datetime_string_from_system(false, true)

	var path = save_file_path(save_id)
	var temp_path = path + ".tmp"
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(output, "\t"))
	file.flush()
	file = null

	if FileAccess.file_exists(path):
		var remove_error = DirAccess.remove_absolute(path)
		if remove_error != OK:
			return false
	return DirAccess.rename_absolute(temp_path, path) == OK


static func summary_from_data(data: Dictionary) -> Dictionary:
	var clock = data.get("clock", {})
	if typeof(clock) != TYPE_DICTIONARY:
		clock = {}
	var player = data.get("player", {})
	if typeof(player) != TYPE_DICTIONARY:
		player = {}
	var ai = data.get("ai", {})
	if typeof(ai) != TYPE_DICTIONARY:
		ai = {}
	var ai_role = data.get("ai_role", {})
	if typeof(ai_role) != TYPE_DICTIONARY:
		ai_role = {}

	return {
		"save_id": str(data.get("save_id", "")),
		"save_name": str(data.get("save_name", data.get("save_id", "未命名存档"))),
		"updated_system_time": str(data.get("updated_system_time", "")),
		"created_system_time": str(data.get("created_system_time", "")),
		"game_minutes": float(clock.get("game_minutes", 0.0)),
		"game_time": _format_game_time(float(clock.get("game_minutes", 0.0))),
		"player_name": str(player.get("name", player.get("profile_id", "玩家"))),
		"ai_name": str(ai_role.get("name", ai.get("name", "AI"))),
	}


static func _format_game_time(game_minutes: float) -> String:
	var total_minutes = int(floor(game_minutes)) % (24 * 60)
	var hour = total_minutes / 60
	var minute = total_minutes % 60
	return "%02d:%02d" % [hour, minute]


static func _safe_id(value: String) -> String:
	var result = value.strip_edges()
	for invalid in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]:
		result = result.replace(invalid, "_")
	result = result.replace(" ", "_")
	result = result.replace("\t", "_")
	if result.strip_edges().is_empty():
		return ""
	return result.left(64)


static func _copy_text_file(source_path: String, target_path: String) -> bool:
	var source = FileAccess.open(source_path, FileAccess.READ)
	if source == null:
		return false
	var text = source.get_as_text()
	source = null

	var target = FileAccess.open(target_path, FileAccess.WRITE)
	if target == null:
		return false
	target.store_string(text)
	target.flush()
	return true
