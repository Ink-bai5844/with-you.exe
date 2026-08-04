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
const BuildCursorScene = preload("res://scripts/visual/build_cursor.gd")
const AreaSelectionOverlayScene = preload("res://scripts/visual/area_selection_overlay.gd")
const PathDebugOverlayScene = preload("res://scripts/visual/path_debug_overlay.gd")

const SETTINGS_FILE_NAME = "settings.json"
const LEGACY_SETTINGS_PATH = "user://settings.json"
const STATUS_UPDATE_INTERVAL_SECONDS = 0.25

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
var build_cursor
var area_selection_overlay
var path_debug_overlay
var settings_path = ""
var _status_update_elapsed = STATUS_UPDATE_INTERVAL_SECONDS
var _build_mode_enabled = false
var _path_debug_enabled = false
var _main_hand_tile_kind = ""
var _hovered_build_tile = Vector2i.ZERO
var _hovered_build_tile_valid = false
var _area_selection_dragging = false
var _area_selection_start_tile = Vector2i.ZERO
var _pending_player_marked_area: Dictionary = {}

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


func _process(delta: float) -> void:
	if player != null and camera != null:
		camera.global_position = camera.global_position.lerp(player.global_position, 0.15)

	_update_build_cursor()
	_update_path_debug_overlay()

	if hud != null and player != null and ai != null:
		_status_update_elapsed += delta
		if _status_update_elapsed >= STATUS_UPDATE_INTERVAL_SECONDS:
			_status_update_elapsed = 0.0
			hud.set_status(clock.snapshot(), player.get_state(), ai.get_state(), llm.is_configured(), _main_hand_tile_kind)
			_update_ai_inventory_view()
			_update_give_item_panel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_exit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and game_started and hud != null:
		if hud.release_chat_focus_if_outside_input(event.position):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton and event.pressed and game_started and _build_mode_enabled and not _is_typing():
		_update_build_cursor(true)
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_player_build_at_tile(_hovered_build_tile)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_try_player_destroy_at_tile(_hovered_build_tile)
			get_viewport().set_input_as_handled()

	if _handle_area_selection_input(event):
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER:
			hud.focus_chat()
		elif event.keycode == KEY_S and event.ctrl_pressed and game_started:
			_save_current_game(true)
		elif event.keycode == KEY_B and game_started and not _is_typing():
			_toggle_build_inventory()
		elif event.keycode == KEY_X and game_started and not _is_typing():
			_toggle_quick_build_mode()
		elif event.keycode == KEY_I and game_started and not _is_typing():
			_toggle_ai_inventory_view()
		elif event.keycode == KEY_G and game_started and not _is_typing():
			_toggle_give_item_panel()
		elif event.keycode == KEY_T and game_started and not _is_typing():
			_toggle_ai_task_panel()
		elif event.keycode == KEY_F3 and game_started and not _is_typing():
			_toggle_path_debug()
		elif event.keycode == KEY_ESCAPE:
			if game_started and _close_build_ui():
				return
			if game_started and _clear_player_marked_area(true):
				return
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
	player.global_position = world.tile_center(Vector2i.ZERO)
	player.set_world(world)
	add_child(player)

	ai = AICompanionScene.new()
	ai.name = "AICompanion"
	ai.global_position = world.tile_center(Vector2i(2, 1))
	ai.set_follow_target(player)
	ai.set_world(world)
	add_child(ai)

	camera = Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	camera.zoom = GameConfig.CAMERA_ZOOM
	camera.position = Vector2.ZERO
	add_child(camera)

	build_cursor = BuildCursorScene.new()
	build_cursor.name = "BuildCursor"
	build_cursor.setup(world, player)
	add_child(build_cursor)

	area_selection_overlay = AreaSelectionOverlayScene.new()
	area_selection_overlay.name = "AreaSelectionOverlay"
	area_selection_overlay.setup(world)
	add_child(area_selection_overlay)

	path_debug_overlay = PathDebugOverlayScene.new()
	path_debug_overlay.name = "PathDebugOverlay"
	path_debug_overlay.setup(world, ai, player)
	add_child(path_debug_overlay)

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
	game_api.register_provider("ai_tasks", func(): return director.tasks_snapshot())
	game_api.register_provider("memory", func(): return memory.snapshot())
	game_api.register_provider("building", func():
		return {
			"buildable_tile_kinds": GameConfig.BUILDABLE_TILE_KINDS,
			"water_buildable_tile_kinds": GameConfig.WATER_BUILDABLE_TILE_KINDS,
			"build_costs": GameConfig.BUILD_COSTS,
			"build_refunds": GameConfig.BUILD_REFUNDS,
			"terrain_destroy_drops": GameConfig.TERRAIN_DESTROY_DROPS,
			"player_build_radius": _player_build_radius(),
		}
	)
	game_api.register_provider("world", func():
		return {
			"seed": world.get_seed(),
			"terrain_tile_kinds": GameConfig.TERRAIN_TILE_KINDS,
			"blocking_tile_kinds": GameConfig.BLOCKING_TILE_KINDS,
			"built_tile_count": world.tile_overrides.size(),
			"terrain_override_count": world.terrain_overrides.size(),
		}
	)
	game_api.register_provider("save", func():
		return {
			"save_id": current_save_id,
			"save_name": current_save_name,
			"game_started": game_started,
		}
	)
	game_api.register_provider("world_focus_area", func():
		var center = world.world_to_tile(ai.global_position if ai != null else player.global_position)
		var size = max(1, int(game_api.get_runtime_parameter("ai.perception_map_tile_size", GameConfig.PERCEPTION_MAP_TILE_SIZE)))
		return world.encode_area_size(center, size)
	)


func _wire_signals() -> void:
	hud.message_submitted.connect(_on_player_message)
	hud.new_save_requested.connect(_on_new_save_requested)
	hud.load_save_requested.connect(_on_load_save_requested)
	hud.save_requested.connect(func(): _save_current_game(true))
	hud.exit_requested.connect(_request_exit)
	hud.exit_choice_selected.connect(_on_exit_choice_selected)
	hud.resolution_selected.connect(_on_resolution_selected)
	hud.main_hand_selected.connect(_on_main_hand_selected)
	hud.give_item_requested.connect(_on_give_item_requested)
	ai.action_event.connect(_on_ai_action_event_for_ui)
	director.ai_spoke.connect(_on_ai_spoke)
	director.ai_tasks_changed.connect(_on_ai_tasks_changed)
	director.debug_event.connect(func(text): hud.append_system("[debug] " + str(text)))
	director.thinking_changed.connect(func(active):
		if active:
			hud.append_system("AI 正在感知与思考...")
	)


func _start_setup() -> void:
	game_started = false
	_main_hand_tile_kind = ""
	_set_build_mode(false)
	_set_path_debug(false)
	_clear_player_marked_area(false)
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
	player.global_position = world.tile_center(Vector2i.ZERO)
	ai.apply_profile(ai_role.get("profile", CharacterProfiles.ai_default()))
	ai.apply_save_data({
		"profile": ai_role.get("profile", CharacterProfiles.ai_default()),
		"position": [world.tile_center(Vector2i(2, 1)).x, world.tile_center(Vector2i(2, 1)).y],
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
	_main_hand_tile_kind = ""
	_set_build_mode(false)
	_set_path_debug(false)
	_clear_player_marked_area(false)
	hud.hide_build_inventory()
	hud.hide_ai_inventory()
	hud.hide_give_item_panel()
	hud.hide_ai_task_panel()
	hud.set_ai_tasks(director.tasks_snapshot())
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
	var marked_area = _pending_player_marked_area.duplicate(true)
	_clear_player_marked_area(false)
	director.on_player_message(text, marked_area)


func _on_ai_spoke(text: String, mood: String) -> void:
	hud.show_ai_dialogue(text, mood)


func _on_ai_tasks_changed(tasks: Array) -> void:
	if hud != null:
		hud.set_ai_tasks(tasks)


func _handle_area_selection_input(event: InputEvent) -> bool:
	if not game_started or _build_mode_enabled or world == null:
		return false

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_area_selection()
				get_viewport().set_input_as_handled()
				return true
			if _area_selection_dragging:
				_finish_area_selection()
				get_viewport().set_input_as_handled()
				return true
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _clear_player_marked_area(true):
				get_viewport().set_input_as_handled()
				return true

	if event is InputEventMouseMotion and _area_selection_dragging:
		_update_area_selection_drag()
		get_viewport().set_input_as_handled()
		return true

	return false


func _begin_area_selection() -> void:
	_area_selection_dragging = true
	_area_selection_start_tile = world.world_to_tile(get_global_mouse_position())
	if area_selection_overlay != null:
		area_selection_overlay.set_drag(_area_selection_start_tile, _area_selection_start_tile)


func _update_area_selection_drag() -> void:
	if not _area_selection_dragging or area_selection_overlay == null:
		return
	var current_tile = world.world_to_tile(get_global_mouse_position())
	area_selection_overlay.set_drag(_area_selection_start_tile, current_tile)


func _finish_area_selection() -> void:
	if not _area_selection_dragging:
		return
	_area_selection_dragging = false
	var end_tile = world.world_to_tile(get_global_mouse_position())
	_pending_player_marked_area = _build_player_marked_area(_area_selection_start_tile, end_tile)
	if area_selection_overlay != null:
		area_selection_overlay.set_selection(_area_selection_start_tile, end_tile)
	var rect: Dictionary = _pending_player_marked_area.get("selected_rect", {})
	hud.append_system("已框选区域 (%d,%d) 到 (%d,%d)，%d x %d 格。下一次发言会把该区域作为玩家主动指示附加给 AI。" % [
		int(rect.get("min_x", 0)),
		int(rect.get("min_y", 0)),
		int(rect.get("max_x", 0)),
		int(rect.get("max_y", 0)),
		int(rect.get("width", 0)),
		int(rect.get("height", 0)),
	])


func _build_player_marked_area(first_tile: Vector2i, second_tile: Vector2i) -> Dictionary:
	var min_tile = Vector2i(min(first_tile.x, second_tile.x), min(first_tile.y, second_tile.y))
	var max_tile = Vector2i(max(first_tile.x, second_tile.x), max(first_tile.y, second_tile.y))
	var player_tile = world.world_to_tile(player.global_position) if player != null else Vector2i.ZERO
	var ai_tile = world.world_to_tile(ai.global_position) if ai != null else Vector2i.ZERO
	return {
		"source": "player_mouse_rectangle_selection",
		"source_type": "player_active_instruction",
		"instruction": "The human player actively selected this rectangular map area with the mouse before sending the current message. Treat this selected_area as player-provided context and an explicit player-directed focus, not as automatic background perception.",
		"selected_rect": {
			"min_tile": [min_tile.x, min_tile.y],
			"max_tile": [max_tile.x, max_tile.y],
			"min_x": min_tile.x,
			"min_y": min_tile.y,
			"max_x": max_tile.x,
			"max_y": max_tile.y,
			"width": max_tile.x - min_tile.x + 1,
			"height": max_tile.y - min_tile.y + 1,
		},
		"selected_at": {
			"game_time": clock.snapshot() if clock != null else {},
			"system_time": Time.get_datetime_string_from_system(false, true),
		},
		"relative_to": {
			"player_tile": [player_tile.x, player_tile.y],
			"ai_tile": [ai_tile.x, ai_tile.y],
		},
		"map": world.encode_area_bounds(min_tile, max_tile),
	}


func _clear_player_marked_area(show_message: bool) -> bool:
	var had_area = _area_selection_dragging or not _pending_player_marked_area.is_empty()
	_area_selection_dragging = false
	_pending_player_marked_area.clear()
	if area_selection_overlay != null:
		area_selection_overlay.clear()
	if show_message and had_area and hud != null:
		hud.append_system("已清除玩家框选区域。")
	return had_area


func _toggle_build_inventory() -> void:
	if hud.is_build_inventory_visible():
		hud.hide_build_inventory()
		return
	hud.show_build_inventory(player.get_state().get("inventory", {}), _main_hand_tile_kind)


func _toggle_quick_build_mode() -> void:
	if _build_mode_enabled:
		_set_build_mode(false)
		hud.append_system("已退出建造模式。")
		return
	if _main_hand_tile_kind.is_empty():
		hud.hide_build_inventory()
		_set_build_mode(true)
		hud.append_system("已进入空手拆除模式。鼠标右键拆除方块，左键建造需要先选择主手方块。")
		return
	hud.hide_build_inventory()
	_set_build_mode(true)
	hud.append_system("已进入建造模式：主手%s。鼠标左键建造，右键拆除。" % GameConfig.tile_label(_main_hand_tile_kind))


func _toggle_ai_task_panel() -> void:
	if hud == null:
		return
	hud.toggle_ai_task_panel()


func _toggle_ai_inventory_view() -> void:
	if hud == null:
		return
	if hud.is_ai_inventory_visible():
		hud.hide_ai_inventory()
		return

	var distance = _ai_tile_distance()
	var max_distance = _ai_inventory_view_distance()
	if distance > max_distance:
		hud.append_system("距离 AI 太远，需在 %d 格以内才能查看背包。当前距离：%d 格。" % [max_distance, distance])
		return

	if _build_mode_enabled:
		_set_build_mode(false)
	hud.hide_build_inventory()
	hud.hide_give_item_panel()
	hud.show_ai_inventory(ai.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, max_distance)
	hud.append_system("正在查看 AI 背包（仅查看）。")


func _toggle_give_item_panel() -> void:
	if hud == null:
		return
	if hud.is_give_item_panel_visible():
		hud.hide_give_item_panel()
		return

	var distance = _ai_tile_distance()
	var max_distance = _ai_item_transfer_distance()
	if distance > max_distance:
		hud.append_system("距离 AI 太远，需在 %d 格以内才能给予物品。当前距离：%d 格。" % [max_distance, distance])
		return

	if _build_mode_enabled:
		_set_build_mode(false)
	hud.hide_build_inventory()
	hud.hide_ai_inventory()
	hud.show_give_item_panel(player.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, max_distance)
	hud.append_system("打开给予面板：只能把你的物品送给 AI。")


func _update_ai_inventory_view() -> void:
	if hud == null or not hud.is_ai_inventory_visible():
		return
	var distance = _ai_tile_distance()
	var max_distance = _ai_inventory_view_distance()
	if distance > max_distance:
		hud.hide_ai_inventory()
		hud.append_system("已离开 AI 身边，关闭 AI 背包。")
		return
	hud.show_ai_inventory(ai.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, max_distance)


func _update_give_item_panel() -> void:
	if hud == null or not hud.is_give_item_panel_visible():
		return
	var distance = _ai_tile_distance()
	var max_distance = _ai_item_transfer_distance()
	if distance > max_distance:
		hud.hide_give_item_panel()
		hud.append_system("已离开 AI 身边，关闭给予面板。")
		return
	hud.show_give_item_panel(player.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, max_distance)


func _toggle_path_debug() -> void:
	_set_path_debug(not _path_debug_enabled)
	if hud != null:
		hud.append_system("寻路调试显示：%s" % ("开" if _path_debug_enabled else "关"))


func _set_path_debug(enabled: bool) -> void:
	_path_debug_enabled = enabled
	if path_debug_overlay != null:
		path_debug_overlay.set_active(enabled)
	if hud != null:
		hud.set_debug_overlay_text(path_debug_overlay.debug_text() if enabled and path_debug_overlay != null else "")


func _update_path_debug_overlay() -> void:
	if path_debug_overlay == null:
		return
	path_debug_overlay.set_active(_path_debug_enabled)
	if not _path_debug_enabled:
		return
	path_debug_overlay.refresh()
	if hud != null:
		hud.set_debug_overlay_text(path_debug_overlay.debug_text())


func _on_main_hand_selected(kind: String) -> void:
	var normalized = GameConfig.normalize_build_kind(kind)
	if normalized.is_empty():
		_main_hand_tile_kind = ""
		hud.hide_build_inventory()
		_set_build_mode(true)
		hud.append_system("主手已切换为空手。鼠标右键可拆除方块，左键建造需要先选择主手方块。")
		return
	if not GameConfig.BUILDABLE_TILE_KINDS.has(normalized):
		hud.append_system("无法把未知方块设为主手：%s。" % kind)
		return
	_main_hand_tile_kind = normalized
	hud.hide_build_inventory()
	_set_build_mode(true)
	hud.append_system("主手方块已切换为%s。鼠标左键建造，右键拆除。" % GameConfig.tile_label(normalized))


func _on_give_item_requested(item_id: String, amount: int) -> void:
	_try_player_give_item_to_ai(item_id, amount)


func _on_ai_action_event_for_ui(event: Dictionary) -> void:
	if hud == null:
		return
	if str(event.get("action_type", "")) != "give_item":
		return
	var item_id = str(event.get("item_id", ""))
	var amount = int(event.get("amount", 0))
	if str(event.get("event_type", "")) == "action_completed":
		hud.append_system("%s 给了你%s x%d。" % [
			str(ai.get_state().get("name", "AI")),
			GameConfig.item_label(item_id),
			amount,
		])
		_refresh_nearby_inventory_panels()
	elif str(event.get("event_type", "")).ends_with("_failed"):
		hud.append_system("%s 想给你物品，但失败了：%s。" % [
			str(ai.get_state().get("name", "AI")),
			_build_error_text({"reason": str(event.get("reason", ""))}),
		])


func _close_build_ui() -> bool:
	var closed = false
	if hud != null and hud.is_build_inventory_visible():
		hud.hide_build_inventory()
		closed = true
	if hud != null and hud.is_ai_inventory_visible():
		hud.hide_ai_inventory()
		closed = true
	if hud != null and hud.is_give_item_panel_visible():
		hud.hide_give_item_panel()
		closed = true
	if _build_mode_enabled:
		_set_build_mode(false)
		hud.append_system("已退出建造模式。")
		closed = true
	return closed


func _set_build_mode(enabled: bool) -> void:
	_build_mode_enabled = enabled
	_update_build_cursor(true)


func _update_build_cursor(force_update = false) -> void:
	if build_cursor == null:
		return
	if not _build_mode_enabled or world == null or player == null:
		build_cursor.set_state(false, Vector2i.ZERO, false, _main_hand_tile_kind, _player_build_radius())
		return

	var tile = world.world_to_tile(get_global_mouse_position())
	var valid = _can_player_target_tile(tile)
	if force_update or tile != _hovered_build_tile or valid != _hovered_build_tile_valid:
		_hovered_build_tile = tile
		_hovered_build_tile_valid = valid
		build_cursor.set_state(true, tile, valid, _main_hand_tile_kind, _player_build_radius())


func _try_player_build_at_tile(tile: Vector2i) -> void:
	if _main_hand_tile_kind.is_empty():
		hud.append_system("主手为空，不能建造；鼠标右键可以拆除方块。")
		return
	if not _can_player_target_tile(tile):
		hud.append_system("目标格超出玩家周围 %d 格范围。" % _player_build_radius())
		return

	var normalized = GameConfig.normalize_build_kind(_main_hand_tile_kind)
	var cost = GameConfig.build_cost(normalized)
	if cost.is_empty():
		hud.append_system("无法建造未知方块：%s。" % _main_hand_tile_kind)
		return
	if not player.has_items(cost):
		hud.append_system("材料不足：建造%s需要%s。" % [GameConfig.tile_label(normalized), _item_stack_text(cost)])
		return
	var result = world.build_tile(tile, normalized)
	if not bool(result.get("ok", false)):
		hud.append_system("无法建造%s：%s。" % [GameConfig.tile_label(normalized), _build_error_text(result)])
		return
	player.consume_items(cost)
	hud.append_system("已在 (%d,%d) 建造%s，消耗%s。" % [
		tile.x,
		tile.y,
		GameConfig.tile_label(normalized),
		_item_stack_text(cost),
	])


func _try_player_destroy_at_tile(tile: Vector2i) -> void:
	if not _can_player_target_tile(tile):
		hud.append_system("目标格超出玩家周围 %d 格范围。" % _player_build_radius())
		return

	var result = world.destroy_tile(tile)
	if not bool(result.get("ok", false)):
		hud.append_system("无法拆除 (%d,%d)：%s。" % [tile.x, tile.y, _build_error_text(result)])
		return
	var removed_kind = str(result.get("removed_kind", ""))
	var refund_value = result.get("refund", GameConfig.build_refund(removed_kind))
	var refund = refund_value.duplicate(true) if typeof(refund_value) == TYPE_DICTIONARY else {}
	player.add_items(refund)
	hud.append_system("已拆除 (%d,%d) 的%s，回收%s。" % [
		tile.x,
		tile.y,
		GameConfig.tile_label(removed_kind),
		_item_stack_text(refund),
	])


func _try_player_give_item_to_ai(item_id: String, amount: int) -> void:
	var normalized_amount = max(1, int(amount))
	var normalized_item = item_id.strip_edges()
	if normalized_item.is_empty():
		return
	var distance = _ai_tile_distance()
	var max_distance = _ai_item_transfer_distance()
	if distance > max_distance:
		hud.hide_give_item_panel()
		hud.append_system("距离 AI 太远，无法给予物品。")
		return
	var stack = {}
	stack[normalized_item] = normalized_amount
	if not player.has_items(stack):
		hud.append_system("你的%s不足，无法送出。" % GameConfig.item_label(normalized_item))
		_refresh_nearby_inventory_panels()
		return
	if not player.consume_items(stack):
		hud.append_system("送出失败：%s不足。" % GameConfig.item_label(normalized_item))
		_refresh_nearby_inventory_panels()
		return
	ai.add_items(stack)
	hud.append_system("你把%s x%d 送给了 %s。" % [
		GameConfig.item_label(normalized_item),
		normalized_amount,
		str(ai.get_state().get("name", "AI")),
	])
	_refresh_nearby_inventory_panels()


func _refresh_nearby_inventory_panels() -> void:
	if hud == null:
		return
	var distance = _ai_tile_distance()
	if hud.is_give_item_panel_visible():
		hud.show_give_item_panel(player.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, _ai_item_transfer_distance())
	if hud.is_ai_inventory_visible():
		hud.show_ai_inventory(ai.get_state().get("inventory", {}), str(ai.get_state().get("name", "AI")), distance, _ai_inventory_view_distance())


func _can_player_target_tile(tile: Vector2i) -> bool:
	if world == null or player == null:
		return false
	var player_tile = world.world_to_tile(player.global_position)
	var offset = tile - player_tile
	if offset == Vector2i.ZERO:
		return false
	if max(abs(offset.x), abs(offset.y)) > _player_build_radius():
		return false
	if ai != null and world.world_to_tile(ai.global_position) == tile:
		return false
	return true


func _player_build_radius() -> int:
	if game_api != null:
		return max(0, int(game_api.get_runtime_parameter("player.build_radius", GameConfig.PLAYER_BUILD_RADIUS)))
	return GameConfig.PLAYER_BUILD_RADIUS


func _ai_inventory_view_distance() -> int:
	if game_api != null:
		return max(0, int(game_api.get_runtime_parameter("ai.inventory_view_distance_tiles", GameConfig.AI_INVENTORY_VIEW_DISTANCE_TILES)))
	return GameConfig.AI_INVENTORY_VIEW_DISTANCE_TILES


func _ai_item_transfer_distance() -> int:
	if game_api != null:
		return max(0, int(game_api.get_runtime_parameter("ai.item_transfer_distance_tiles", GameConfig.AI_ITEM_TRANSFER_DISTANCE_TILES)))
	return GameConfig.AI_ITEM_TRANSFER_DISTANCE_TILES


func _ai_tile_distance() -> int:
	if world == null or player == null or ai == null:
		return 2147483647
	var player_tile = world.world_to_tile(player.global_position)
	var ai_tile = world.world_to_tile(ai.global_position)
	var offset = ai_tile - player_tile
	return max(abs(offset.x), abs(offset.y))


func _item_stack_text(items: Dictionary) -> String:
	if items.is_empty():
		return "无"
	var parts = []
	for item_id in items.keys():
		parts.append("%s x%d" % [GameConfig.item_label(str(item_id)), int(items[item_id])])
	return "、".join(parts)


func _build_error_text(result: Dictionary) -> String:
	match str(result.get("reason", "")):
		"occupied":
			return "目标格已有建造方块"
		"invalid_base_tile":
			return "不能在%s上建造" % GameConfig.tile_label(str(result.get("base_kind", "")))
		"no_built_tile":
			return "目标格没有可拆除的建造方块"
		"no_destroyable_tile":
			return "目标格没有可拆除的建造方块或可破坏的自然资源"
		"not_buildable":
			return "该方块类型不可建造"
		"missing_items":
			return "材料不足"
		"recipient_too_far":
			return "距离太远"
		"no_valid_recipient":
			return "没有可接收物品的对象"
		"consume_failed":
			return "扣除物品失败"
		_:
			return str(result.get("reason", "未知原因"))


func _is_typing() -> bool:
	var focus = get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


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
