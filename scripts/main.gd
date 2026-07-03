extends Node2D

const GameConfig = preload("res://scripts/config/game_config.gd")
const CharacterProfiles = preload("res://scripts/profiles/character_profiles.gd")
const AIRoleLibrary = preload("res://scripts/profiles/ai_role_library.gd")
const WorldRendererScene = preload("res://scripts/world/world_renderer.gd")
const PlayerScene = preload("res://scripts/entities/player.gd")
const AICompanionScene = preload("res://scripts/entities/ai_companion.gd")
const HUDScene = preload("res://scripts/ui/hud.gd")
const LLMClientScene = preload("res://scripts/services/llm_client.gd")
const AIMemoryStoreScene = preload("res://scripts/ai/ai_memory_store.gd")
const AIDirectorScene = preload("res://scripts/ai/ai_director.gd")
const GameClockScene = preload("res://scripts/core/game_clock.gd")
const GameAPIScene = preload("res://scripts/core/game_api.gd")
const AppPaths = preload("res://scripts/core/app_paths.gd")
const SaveManager = preload("res://scripts/core/save_manager.gd")

const SETTINGS_FILE_NAME = "settings.json"
const LEGACY_SETTINGS_PATH = "user://settings.json"

var world
var player
var ai
var hud
var clock
var llm
var memory
var director
var game_api
var camera: Camera2D
var settings_path = ""

var game_started = false
var current_save_id = ""
var current_save_name = ""
var current_ai_role: Dictionary = {}


func _ready() -> void:
	randomize()
	if DisplayServer.get_name() != "headless":
		get_tree().auto_accept_quit = false
	settings_path = AppPaths.migrated_user_data_file(SETTINGS_FILE_NAME, LEGACY_SETTINGS_PATH)
	_apply_resolution(_load_saved_resolution())
	_create_core_nodes()
	_register_runtime_api()
	_wire_signals()
	_start_setup()


func _process(_delta: float) -> void:
	if player != null and camera != null:
		camera.global_position = camera.global_position.lerp(player.global_position, 0.15)

	if hud != null and player != null and ai != null:
		hud.set_status(clock.snapshot(), player.get_state(), ai.get_state(), llm.is_configured())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_exit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER:
			hud.focus_chat()
		elif event.keycode == KEY_S and event.ctrl_pressed and game_started:
			_save_current_game(true)
		elif event.keycode == KEY_ESCAPE:
			_request_exit()


func _create_core_nodes() -> void:
	game_api = GameAPIScene.new()
	game_api.name = "GameAPI"
	add_child(game_api)

	clock = GameClockScene.new()
	clock.name = "GameClock"
	add_child(clock)

	world = WorldRendererScene.new()
	world.name = "World"
	world.z_index = -10
	add_child(world)

	player = PlayerScene.new()
	player.name = "Player"
	player.global_position = Vector2.ZERO
	add_child(player)

	ai = AICompanionScene.new()
	ai.name = "AICompanion"
	ai.global_position = Vector2(32, 24)
	ai.set_follow_target(player)
	ai.set_world(world)
	add_child(ai)

	camera = Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	camera.zoom = GameConfig.CAMERA_ZOOM
	camera.position = Vector2.ZERO
	add_child(camera)

	var canvas = CanvasLayer.new()
	canvas.name = "HUDLayer"
	add_child(canvas)

	hud = HUDScene.new()
	hud.name = "HUD"
	canvas.add_child(hud)

	llm = LLMClientScene.new()
	llm.name = "LLMClient"
	add_child(llm)

	memory = AIMemoryStoreScene.new()
	memory.name = "AIMemoryStore"
	add_child(memory)

	director = AIDirectorScene.new()
	director.name = "AIDirector"
	add_child(director)
	director.setup(world, player, ai, memory, llm, clock, game_api)


func _register_runtime_api() -> void:
	game_api.register_provider("clock", func(): return clock.snapshot())
	game_api.register_provider("player", func(): return player.get_state())
	game_api.register_provider("ai", func(): return ai.get_state())
	game_api.register_provider("memory", func(): return memory.snapshot())
	game_api.register_provider("save", func():
		return {
			"save_id": current_save_id,
			"save_name": current_save_name,
			"game_started": game_started,
		}
	)
	game_api.register_provider("world_focus_area", func():
		var center = world.world_to_tile(player.global_position)
		return world.encode_area(center, 8)
	)


func _wire_signals() -> void:
	hud.message_submitted.connect(_on_player_message)
	hud.new_save_requested.connect(_on_new_save_requested)
	hud.load_save_requested.connect(_on_load_save_requested)
	hud.save_requested.connect(func(): _save_current_game(true))
	hud.exit_requested.connect(_request_exit)
	hud.exit_choice_selected.connect(_on_exit_choice_selected)
	hud.resolution_selected.connect(_on_resolution_selected)
	director.ai_spoke.connect(_on_ai_spoke)
	director.debug_event.connect(func(text): hud.append_system("[debug] " + str(text)))
	director.thinking_changed.connect(func(active):
		if active:
			hud.append_system("AI 正在感知与思考...")
	)


func _start_setup() -> void:
	game_started = false
	player.set_controls_enabled(false)
	hud.set_ingame_controls_enabled(false)
	world.set_seed(GameConfig.DEFAULT_WORLD_SEED)
	hud.append_system("欢迎来到 With You。请选择新建存档或读取存档。")
	hud.append_system("LLM 接口读取 config/llm_config.json 和环境变量；未配置时使用离线占位 AI。")
	_migrate_global_memory_if_needed()
	_show_start_menu()


func _show_start_menu() -> void:
	hud.show_start_menu(SaveManager.list_saves(), CharacterProfiles.player_presets(), AIRoleLibrary.load_roles())


func _migrate_global_memory_if_needed() -> void:
	if not SaveManager.has_global_memory_files():
		return

	var player_preset = CharacterProfiles.player_presets()[0].duplicate(true)
	var ai_role = AIRoleLibrary.find_role("default_mobai", AIRoleLibrary.load_roles())
	var ai_profile: Dictionary = ai_role.get("profile", CharacterProfiles.ai_default()).duplicate(true)
	var migrated = SaveManager.migrate_global_memory_to_save("legacy_global", {
		"save_name": "旧全局存档",
		"world": {"seed": GameConfig.DEFAULT_WORLD_SEED},
		"clock": {
			"game_minutes": GameConfig.START_GAME_MINUTES,
			"minutes_per_real_second": GameConfig.GAME_MINUTES_PER_REAL_SECOND,
		},
		"player": {
			"profile": player_preset,
			"profile_id": player_preset.get("id", "settler"),
			"name": player_preset.get("name", "玩家"),
			"position": [0.0, 0.0],
			"attributes": player_preset.get("attributes", {}).duplicate(true),
			"skills": player_preset.get("skills", []).duplicate(true),
			"facing": "down",
		},
		"ai": {
			"profile": ai_profile,
			"profile_id": ai_profile.get("id", "companion_ai"),
			"name": ai_profile.get("name", "AI"),
			"position": [32.0, 24.0],
			"attributes": ai_profile.get("attributes", {}).duplicate(true),
			"skills": ai_profile.get("skills", []).duplicate(true),
			"mood": "calm",
			"facing": "down",
			"follow_enabled": false,
			"current_action": {},
			"action_queue": [],
		},
		"ai_role": ai_role.duplicate(true),
		"director": {
			"started": true,
			"ai_prompt": ai_role.get("prompt", {}).duplicate(true),
		},
	}, true)
	if migrated:
		hud.append_system("已把旧全局记忆迁移为存档：旧全局存档。")


func _on_new_save_requested(selection: Dictionary) -> void:
	var save_name = str(selection.get("save_name", "")).strip_edges()
	if save_name.is_empty():
		save_name = "新的生活"
	var save_id = SaveManager.create_save_id(save_name)
	var player_preset: Dictionary = selection.get("player_preset", {})
	var ai_role: Dictionary = selection.get("ai_role", AIRoleLibrary.find_role("default_mobai"))

	current_save_id = save_id
	current_save_name = save_name
	current_ai_role = ai_role.duplicate(true)

	director.stop()
	memory.set_storage_dir(SaveManager.memory_dir(current_save_id), false)
	world.set_seed(randi())
	clock.apply_save_data({
		"game_minutes": GameConfig.START_GAME_MINUTES,
		"minutes_per_real_second": GameConfig.GAME_MINUTES_PER_REAL_SECOND,
	})
	player.apply_preset(player_preset)
	player.global_position = Vector2.ZERO
	ai.apply_profile(ai_role.get("profile", CharacterProfiles.ai_default()))
	ai.apply_save_data({
		"profile": ai_role.get("profile", CharacterProfiles.ai_default()),
		"position": [32.0, 24.0],
		"mood": "calm",
		"facing": "down",
		"follow_enabled": false,
		"current_action": {},
		"action_queue": [],
	})
	director.set_ai_prompt(ai_role.get("prompt", {}))
	_begin_game()
	_save_current_game(false)
	hud.append_system("已创建存档：%s" % current_save_name)


func _on_load_save_requested(save_id: String) -> void:
	var data = SaveManager.load_save(save_id)
	if data.is_empty():
		hud.append_system("读取失败：找不到存档 %s" % save_id)
		_show_start_menu()
		return

	current_save_id = str(data.get("save_id", save_id))
	current_save_name = str(data.get("save_name", current_save_id))
	current_ai_role = data.get("ai_role", AIRoleLibrary.find_role("default_mobai")).duplicate(true)

	director.stop()
	memory.set_storage_dir(SaveManager.memory_dir(current_save_id), true)
	world.apply_save_data(data.get("world", {}))
	clock.apply_save_data(data.get("clock", {}))
	player.apply_save_data(data.get("player", {}))
	if typeof(current_ai_role.get("profile", null)) == TYPE_DICTIONARY:
		ai.apply_profile(current_ai_role["profile"])
	ai.apply_save_data(data.get("ai", {}))
	if typeof(current_ai_role.get("prompt", null)) == TYPE_DICTIONARY:
		director.set_ai_prompt(current_ai_role["prompt"])
	director.apply_save_data(data.get("director", {"started": true}))
	_begin_game(false)
	hud.append_system("已读取存档：%s" % current_save_name)


func _begin_game(reset_director = true) -> void:
	game_started = true
	player.set_controls_enabled(true)
	hud.set_ingame_controls_enabled(true)
	hud.hide_setup_overlay()
	if reset_director:
		director.begin()
	camera.global_position = player.global_position


func _save_current_game(show_message: bool) -> bool:
	if current_save_id.is_empty() or not game_started:
		if show_message:
			hud.append_system("当前没有可保存的存档。")
		return false

	memory.save_memory()
	var data = {
		"save_name": current_save_name,
		"world": world.get_save_data(),
		"clock": clock.get_save_data(),
		"player": player.get_save_data(),
		"ai": ai.get_save_data(),
		"ai_role": current_ai_role.duplicate(true),
		"director": director.get_save_data(),
	}
	var ok = SaveManager.write_save(current_save_id, data)
	if show_message:
		hud.append_system("存档已保存。" if ok else "存档保存失败。")
	return ok


func _request_exit() -> void:
	if game_started:
		hud.show_exit_confirm()
	else:
		get_tree().quit()


func _on_exit_choice_selected(choice: String) -> void:
	if choice == "save_quit":
		_save_current_game(false)
		get_tree().quit()
	elif choice == "quit":
		get_tree().quit()


func _on_player_message(text: String) -> void:
	if not game_started:
		return
	director.on_player_message(text)


func _on_ai_spoke(text: String, mood: String) -> void:
	hud.show_ai_dialogue(text, mood)


func _on_resolution_selected(size: Vector2i) -> void:
	_apply_resolution(size)
	_save_resolution(size)
	hud.append_system("分辨率已切换为 %d x %d。" % [size.x, size.y])


func _apply_resolution(size: Vector2i) -> void:
	get_tree().root.content_scale_size = size
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(size)
		_center_window(size)


func _center_window(size: Vector2i) -> void:
	var screen = DisplayServer.window_get_current_screen()
	var screen_position = DisplayServer.screen_get_position(screen)
	var screen_size = DisplayServer.screen_get_size(screen)
	var window_position = screen_position + (screen_size - size) / 2
	DisplayServer.window_set_position(window_position)


func _load_saved_resolution() -> Vector2i:
	if settings_path.is_empty():
		settings_path = AppPaths.migrated_user_data_file(SETTINGS_FILE_NAME, LEGACY_SETTINGS_PATH)
	if not FileAccess.file_exists(settings_path):
		return GameConfig.DEFAULT_RESOLUTION
	var file = FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		return GameConfig.DEFAULT_RESOLUTION
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return GameConfig.DEFAULT_RESOLUTION
	var resolution = parsed.get("resolution", {})
	if typeof(resolution) != TYPE_DICTIONARY:
		return GameConfig.DEFAULT_RESOLUTION
	return _validated_resolution(Vector2i(
		int(resolution.get("width", GameConfig.DEFAULT_RESOLUTION.x)),
		int(resolution.get("height", GameConfig.DEFAULT_RESOLUTION.y))
	))


func _save_resolution(size: Vector2i) -> void:
	if settings_path.is_empty():
		settings_path = AppPaths.migrated_user_data_file(SETTINGS_FILE_NAME, LEGACY_SETTINGS_PATH)
	var file = FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"resolution": {
			"width": size.x,
			"height": size.y,
		}
	}, "\t"))


func _validated_resolution(size: Vector2i) -> Vector2i:
	for option in GameConfig.RESOLUTION_OPTIONS:
		if option == size:
			return size
	return GameConfig.DEFAULT_RESOLUTION
