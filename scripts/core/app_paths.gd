class_name AppPaths
extends RefCounted

const USER_DATA_DIR_NAME = "user_data"


static func user_data_file(file_name: String) -> String:
	return user_data_dir().path_join(file_name)


static func user_data_subdir(dir_name: String) -> String:
	var dir_path = user_data_dir().path_join(dir_name)
	_ensure_absolute_dir(dir_path)
	return dir_path


static func migrated_user_data_file(file_name: String, legacy_path: String) -> String:
	var target_path = user_data_file(file_name)
	if FileAccess.file_exists(target_path) or legacy_path.is_empty() or not FileAccess.file_exists(legacy_path):
		return target_path

	var legacy_file = FileAccess.open(legacy_path, FileAccess.READ)
	if legacy_file == null:
		return target_path
	var text = legacy_file.get_as_text()
	legacy_file = null

	var target_file = FileAccess.open(target_path, FileAccess.WRITE)
	if target_file == null:
		return target_path
	target_file.store_string(text)
	target_file.flush()
	return target_path


static func user_data_dir() -> String:
	var preferred_dir = _program_dir().path_join(USER_DATA_DIR_NAME)
	if _dir_is_writable(preferred_dir):
		return preferred_dir

	var fallback_dir = ProjectSettings.globalize_path("user://").path_join(USER_DATA_DIR_NAME)
	_dir_is_writable(fallback_dir)
	return fallback_dir


static func _program_dir() -> String:
	if OS.has_feature("editor"):
		return _trim_path(ProjectSettings.globalize_path("res://"))

	var executable_path = OS.get_executable_path()
	if executable_path.is_empty():
		return _trim_path(ProjectSettings.globalize_path("res://"))
	return _trim_path(executable_path.get_base_dir())


static func _ensure_absolute_dir(path: String) -> bool:
	if path.is_empty():
		return false
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK


static func _dir_is_writable(path: String) -> bool:
	if not _ensure_absolute_dir(path):
		return false

	var probe_path = path.path_join(".write_test.tmp")
	var probe = FileAccess.open(probe_path, FileAccess.WRITE)
	if probe == null:
		return false
	probe.store_string("ok")
	probe.flush()
	probe = null
	DirAccess.remove_absolute(probe_path)
	return true


static func _trim_path(path: String) -> String:
	return path.trim_suffix("/").trim_suffix("\\")
