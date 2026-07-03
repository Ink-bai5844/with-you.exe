class_name AIRoleLibrary
extends RefCounted

const AppPaths = preload("res://scripts/core/app_paths.gd")
const CharacterProfiles = preload("res://scripts/profiles/character_profiles.gd")

const ROLES_DIR_NAME = "roles"
const DEFAULT_PROMPT_PATH = "res://config/ai_prompt.json"
const DEFAULT_MOBAI_SPRITE_SHEET = {
	"path": "res://assets/characters/inkbai/sprites/inkbai-move.png",
	"columns": 12,
	"rows": 1,
	"frames_per_direction": 3,
	"fps": 6.0,
	"idle_frame": 0,
	"walk_sequence": "2131",
	"frame_width": 55,
	"draw_size": [27, 41],
	"bottom_y": 12.0,
	"direction_frames": {"down": 0, "right": 3, "left": 6, "up": 9},
}


static func roles_dir() -> String:
	return AppPaths.user_data_subdir(ROLES_DIR_NAME)


static func load_roles() -> Array:
	var roles = [_default_role()]
	var dir = DirAccess.open(roles_dir())
	if dir == null:
		return roles

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "json":
			var role = _load_role_file(roles_dir().path_join(file_name), file_name.get_basename())
			if not role.is_empty():
				roles.append(role)
		file_name = dir.get_next()
	dir.list_dir_end()
	return roles


static func find_role(role_id: String, roles: Array = []) -> Dictionary:
	var source_roles = roles if not roles.is_empty() else load_roles()
	for role in source_roles:
		if typeof(role) == TYPE_DICTIONARY and str(role.get("id", "")) == role_id:
			return role.duplicate(true)
	return _default_role()


static func _default_role() -> Dictionary:
	var prompt = _load_prompt(DEFAULT_PROMPT_PATH)
	var profile = CharacterProfiles.ai_default()
	var character_name = str(prompt.get("character_name", "墨白"))
	profile["id"] = "default_mobai"
	profile["name"] = character_name
	profile["description"] = str(prompt.get("role", profile.get("description", "")))
	profile["sprite_sheet"] = DEFAULT_MOBAI_SPRITE_SHEET.duplicate(true)
	return {
		"id": "default_mobai",
		"name": character_name,
		"description": str(prompt.get("role", "")),
		"prompt": prompt,
		"profile": profile,
		"source_path": DEFAULT_PROMPT_PATH,
	}


static func _load_role_file(path: String, fallback_id: String) -> Dictionary:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return _normalize_role(parsed, fallback_id, path)


static func _normalize_role(data: Dictionary, fallback_id: String, source_path: String) -> Dictionary:
	var prompt = {}
	if typeof(data.get("prompt", null)) == TYPE_DICTIONARY:
		prompt = data["prompt"].duplicate(true)
	else:
		for key in ["character_name", "role", "background", "personality", "speaking_style", "relationship_to_player", "extra_system_prompt"]:
			if data.has(key):
				prompt[key] = data[key]

	var base_prompt = _load_prompt(DEFAULT_PROMPT_PATH)
	for key in base_prompt.keys():
		if not prompt.has(key):
			prompt[key] = base_prompt[key]

	var profile = CharacterProfiles.ai_default()
	if typeof(data.get("profile", null)) == TYPE_DICTIONARY:
		var custom_profile: Dictionary = data["profile"]
		for key in custom_profile.keys():
			profile[key] = custom_profile[key]

	for key in ["attributes", "skills"]:
		if data.has(key):
			profile[key] = data[key]
	if typeof(data.get("sprite_sheet", null)) == TYPE_DICTIONARY:
		profile["sprite_sheet"] = data["sprite_sheet"].duplicate(true)
	elif not profile.has("sprite_sheet") and str(data.get("id", fallback_id)) == "default_mobai":
		profile["sprite_sheet"] = DEFAULT_MOBAI_SPRITE_SHEET.duplicate(true)

	var role_id = str(data.get("id", fallback_id)).strip_edges()
	if role_id.is_empty():
		role_id = fallback_id
	var name = str(data.get("name", data.get("display_name", prompt.get("character_name", role_id)))).strip_edges()
	if name.is_empty():
		name = role_id
	profile["id"] = str(profile.get("id", role_id))
	profile["name"] = name
	profile["description"] = str(data.get("description", prompt.get("role", profile.get("description", ""))))
	prompt["character_name"] = str(prompt.get("character_name", name))

	return {
		"id": role_id,
		"name": name,
		"description": str(data.get("description", prompt.get("role", ""))),
		"prompt": prompt,
		"profile": profile,
		"source_path": source_path,
	}


static func _load_prompt(path: String) -> Dictionary:
	var fallback = {
		"character_name": "墨白",
		"role": "AI player and companion in a 2D pixel sandbox life game.",
		"background": "",
		"personality": ["gentle", "curious", "observant", "proactive"],
		"speaking_style": "Speak concise, natural Chinese as an in-world companion.",
		"relationship_to_player": "The player is your companion for living, exploring, and developing the world together.",
		"extra_system_prompt": "",
	}
	if not FileAccess.file_exists(path):
		return fallback
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return fallback
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return fallback
	for key in parsed.keys():
		fallback[key] = parsed[key]
	return fallback
