class_name HUD
extends Control

signal message_submitted(text)
signal new_save_requested(selection)
signal load_save_requested(save_id)
signal save_requested()
signal exit_requested()
signal exit_choice_selected(choice)
signal resolution_selected(size)
signal main_hand_selected(tile_kind)

const GameConfig = preload("res://scripts/config/game_config.gd")
const PortraitViewScene = preload("res://scripts/visual/portrait_view.gd")
const DEFAULT_AI_PORTRAIT_DIR = "res://assets/characters/inkbai/portraits"
const INVENTORY_COLUMNS = 9
const INVENTORY_VISIBLE_SLOTS = 27
const INVENTORY_SLOT_SIZE = Vector2(58, 58)
const INVENTORY_ICON_SIZE = Vector2(34, 34)

var _status_label: Label
var _log: RichTextLabel
var _input: LineEdit
var _send_button: Button
var _save_button: Button
var _exit_button: Button
var _debug_overlay_panel: PanelContainer
var _debug_overlay_label: Label
var _task_panel: PanelContainer
var _task_list_box: VBoxContainer
var _dialogue_panel: PanelContainer
var _dialogue_portrait
var _dialogue_label: Label
var _dialogue_timer: Timer
var _build_inventory_panel: PanelContainer
var _build_inventory_box: VBoxContainer
var _setup_overlay: CenterContainer
var _setup_panel: PanelContainer
var _setup_box: VBoxContainer
var _resolution_option: OptionButton
var _ai_portrait
var _player_portrait

var _cached_saves: Array = []
var _cached_player_presets: Array = []
var _cached_ai_roles: Array = []
var _last_status_text = ""
var _last_ai_status_mood = ""
var _inventory_icon_cache: Dictionary = {}
var _cached_ai_tasks: Array = []


func _ready() -> void:
	_fill_viewport()
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_status()
	_build_debug_overlay()
	_build_task_panel()
	_build_chat()
	_build_ai_dialogue_popup()
	_build_build_inventory_panel()
	_build_setup_panel()
	set_ingame_controls_enabled(false)
	get_viewport().size_changed.connect(_fill_viewport)


func show_start_menu(saves: Array, player_presets: Array, ai_roles: Array) -> void:
	_cached_saves = saves.duplicate(true)
	_cached_player_presets = player_presets.duplicate(true)
	_cached_ai_roles = ai_roles.duplicate(true)
	_clear_setup_box()

	_add_title("With You")
	_build_resolution_selector()
	_add_button("新建存档", func(): _show_new_save_menu())

	var load_title = Label.new()
	load_title.text = "读取存档"
	load_title.custom_minimum_size = Vector2(0, 28)
	load_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_setup_box.add_child(load_title)

	if saves.is_empty():
		var empty = Label.new()
		empty.text = "暂无可读取存档"
		empty.modulate = Color("aeb8c2")
		_setup_box.add_child(empty)
	else:
		for save in saves:
			var save_copy = save.duplicate(true)
			var text = "%s | %s | %s | AI:%s" % [
				save_copy.get("save_name", "未命名存档"),
				save_copy.get("game_time", "--:--"),
				save_copy.get("updated_system_time", ""),
				save_copy.get("ai_name", "AI"),
			]
			_add_button(text, func(): _select_load_save(save_copy))

	_setup_overlay.visible = true


func hide_setup_overlay() -> void:
	_setup_overlay.visible = false


func set_ingame_controls_enabled(enabled: bool) -> void:
	if _save_button != null:
		_save_button.disabled = not enabled
	if _exit_button != null:
		_exit_button.disabled = false
	if _input != null:
		_input.editable = enabled
	if _send_button != null:
		_send_button.disabled = not enabled
	if not enabled:
		hide_build_inventory()
		hide_ai_task_panel()


func show_build_inventory(player_inventory: Dictionary, selected_kind: String) -> void:
	if _build_inventory_panel == null:
		return
	_populate_build_inventory(player_inventory, selected_kind)
	_build_inventory_panel.visible = true


func hide_build_inventory() -> void:
	if _build_inventory_panel != null:
		_build_inventory_panel.visible = false


func is_build_inventory_visible() -> bool:
	return _build_inventory_panel != null and _build_inventory_panel.visible


func set_ai_tasks(tasks: Array) -> void:
	_cached_ai_tasks = tasks.duplicate(true)
	_populate_task_panel()


func show_ai_task_panel() -> void:
	if _task_panel == null:
		return
	_populate_task_panel()
	_task_panel.visible = true


func hide_ai_task_panel() -> void:
	if _task_panel != null:
		_task_panel.visible = false


func toggle_ai_task_panel() -> void:
	if _task_panel == null:
		return
	if _task_panel.visible:
		hide_ai_task_panel()
	else:
		show_ai_task_panel()


func is_ai_task_panel_visible() -> bool:
	return _task_panel != null and _task_panel.visible


func show_exit_confirm() -> void:
	_clear_setup_box()
	_add_title("退出游戏")

	var label = Label.new()
	label.text = "是否在退出前保存当前存档？"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(0, 36)
	_setup_box.add_child(label)

	_add_button("保存并退出", func(): _select_exit_choice("save_quit"))
	_add_button("直接退出", func(): _select_exit_choice("quit"))
	_add_button("取消", func(): _select_exit_choice("cancel"))
	_setup_overlay.visible = true


func append_system(text: String) -> void:
	_log.append_text("[color=#aeb8c2]%s[/color]\n" % text)


func append_chat(speaker: String, text: String, color = "#ffffff") -> void:
	_log.append_text("[color=%s]%s[/color] %s\n" % [color, speaker, text])


func show_ai_dialogue(text: String, mood: String) -> void:
	var trimmed = text.strip_edges()
	if trimmed.is_empty():
		return
	_dialogue_portrait.set_character(true, mood)
	_dialogue_label.text = trimmed
	_dialogue_panel.visible = true
	_dialogue_timer.stop()
	_dialogue_timer.wait_time = clamp(3.5 + float(trimmed.length()) / 18.0, 4.0, 12.0)
	_dialogue_timer.start()


func set_debug_overlay_text(text: String) -> void:
	if _debug_overlay_panel == null or _debug_overlay_label == null:
		return
	var trimmed = text.strip_edges()
	_debug_overlay_label.text = trimmed
	_debug_overlay_panel.visible = not trimmed.is_empty()


func set_status(clock_snapshot: Dictionary, player_state: Dictionary, ai_state: Dictionary, llm_ready: bool, main_hand_kind = "") -> void:
	var player_name = player_state.get("name", "玩家")
	var ai_name = ai_state.get("name", "AI")
	var player_attr: Dictionary = player_state.get("attributes", {})
	var ai_attr: Dictionary = ai_state.get("attributes", {})
	var ai_mood = str(ai_state.get("mood", "calm"))
	var main_hand = GameConfig.tile_label(str(main_hand_kind)) if not str(main_hand_kind).is_empty() else "无"
	var status_text = "时间 %s | LLM %s | 主手:%s | %s HP:%s EN:%s | %s 心情:%s HP:%s EN:%s" % [
		clock_snapshot.get("game_time", "--:--"),
		"在线" if llm_ready else "离线占位",
		main_hand,
		player_name,
		player_attr.get("health", "-"),
		player_attr.get("energy", "-"),
		ai_name,
		ai_mood,
		ai_attr.get("health", "-"),
		ai_attr.get("energy", "-"),
	]
	status_text += " | 跟随:%s" % ("开" if bool(ai_state.get("follow_enabled", false)) else "关")
	if status_text != _last_status_text:
		_last_status_text = status_text
		_status_label.text = status_text
	if ai_mood != _last_ai_status_mood:
		_last_ai_status_mood = ai_mood
		_ai_portrait.set_character(true, ai_mood)


func focus_chat() -> void:
	if _input.editable:
		_input.grab_focus()


func release_chat_focus_if_outside_input(screen_position: Vector2) -> bool:
	if _input == null or not _input.has_focus():
		return false
	if _input.get_global_rect().has_point(screen_position):
		return false
	_input.release_focus()
	return true


func _build_status() -> void:
	var panel = PanelContainer.new()
	panel.anchor_right = 1.0
	panel.offset_left = 8
	panel.offset_top = 8
	panel.offset_right = -8
	panel.offset_bottom = 74
	add_child(panel)

	var row = HBoxContainer.new()
	panel.add_child(row)

	_player_portrait = PortraitViewScene.new()
	_player_portrait.custom_minimum_size = Vector2(52, 52)
	_player_portrait.set_character(false, "calm")
	row.add_child(_player_portrait)

	_ai_portrait = PortraitViewScene.new()
	_ai_portrait.custom_minimum_size = Vector2(52, 52)
	_ai_portrait.set_portrait_dir(DEFAULT_AI_PORTRAIT_DIR)
	_ai_portrait.set_character(true, "calm")
	row.add_child(_ai_portrait)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 52)
	row.add_child(_status_label)

	_save_button = Button.new()
	_save_button.text = "保存"
	_save_button.custom_minimum_size = Vector2(72, 40)
	_save_button.pressed.connect(func(): save_requested.emit())
	row.add_child(_save_button)

	_exit_button = Button.new()
	_exit_button.text = "退出"
	_exit_button.custom_minimum_size = Vector2(72, 40)
	_exit_button.pressed.connect(func(): exit_requested.emit())
	row.add_child(_exit_button)


func _build_debug_overlay() -> void:
	_debug_overlay_panel = PanelContainer.new()
	_debug_overlay_panel.anchor_left = 1.0
	_debug_overlay_panel.anchor_right = 1.0
	_debug_overlay_panel.anchor_top = 0.0
	_debug_overlay_panel.anchor_bottom = 0.0
	_debug_overlay_panel.offset_left = -620
	_debug_overlay_panel.offset_right = -12
	_debug_overlay_panel.offset_top = 82
	_debug_overlay_panel.offset_bottom = 132
	_debug_overlay_panel.visible = false
	_debug_overlay_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.06, 0.78)
	style.border_color = Color(0.18, 0.70, 1.0, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	_debug_overlay_panel.add_theme_stylebox_override("panel", style)
	add_child(_debug_overlay_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 6)
	_debug_overlay_panel.add_child(margin)

	_debug_overlay_label = Label.new()
	_debug_overlay_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_debug_overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_overlay_label.add_theme_font_size_override("font_size", 14)
	_debug_overlay_label.add_theme_color_override("font_color", Color("d7f1ff"))
	margin.add_child(_debug_overlay_label)


func _build_task_panel() -> void:
	_task_panel = PanelContainer.new()
	_task_panel.anchor_left = 0.0
	_task_panel.anchor_right = 0.0
	_task_panel.anchor_top = 0.0
	_task_panel.anchor_bottom = 1.0
	_task_panel.offset_left = 10
	_task_panel.offset_right = 366
	_task_panel.offset_top = 86
	_task_panel.offset_bottom = -190
	_task_panel.visible = false
	_task_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.05, 0.055, 0.90)
	style.border_color = Color(0.34, 0.40, 0.46, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	_task_panel.add_theme_stylebox_override("panel", style)
	add_child(_task_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_task_panel.add_child(margin)

	var panel_box = VBoxContainer.new()
	panel_box.add_theme_constant_override("separation", 8)
	margin.add_child(panel_box)

	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	panel_box.add_child(title_row)

	var title = Label.new()
	title.text = "AI任务"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("edf2f6"))
	title_row.add_child(title)

	var close_button = Button.new()
	close_button.text = "T"
	close_button.tooltip_text = "关闭任务列表"
	close_button.custom_minimum_size = Vector2(42, 30)
	close_button.pressed.connect(hide_ai_task_panel)
	title_row.add_child(close_button)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_box.add_child(scroll)

	_task_list_box = VBoxContainer.new()
	_task_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_task_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_task_list_box)


func _populate_task_panel() -> void:
	if _task_list_box == null:
		return
	for child in _task_list_box.get_children():
		_task_list_box.remove_child(child)
		child.queue_free()

	if _cached_ai_tasks.is_empty():
		var empty = Label.new()
		empty.text = "暂无任务"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size = Vector2(0, 48)
		empty.add_theme_color_override("font_color", Color("aeb8c2"))
		_task_list_box.add_child(empty)
		return

	for task in _cached_ai_tasks:
		if typeof(task) == TYPE_DICTIONARY:
			_task_list_box.add_child(_task_row(task))


func _task_row(task: Dictionary) -> Control:
	var panel = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.tooltip_text = _task_tooltip(task)
	panel.add_theme_stylebox_override("panel", _task_row_style(str(task.get("status", "pending"))))

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)

	var head = Label.new()
	head.text = "%s  %s" % [_task_status_label(str(task.get("status", "pending"))), str(task.get("title", "未命名任务")).left(26)]
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_theme_font_size_override("font_size", 14)
	head.add_theme_color_override("font_color", Color("f4f4f4"))
	box.add_child(head)

	var meta = Label.new()
	meta.text = "%s | 优先级 %d | %s" % [
		str(task.get("id", "")),
		int(task.get("priority", 5)),
		str(task.get("kind", "general")),
	]
	meta.add_theme_font_size_override("font_size", 12)
	meta.add_theme_color_override("font_color", Color("b8c1ca"))
	box.add_child(meta)

	var objective = Label.new()
	objective.text = str(task.get("objective", "")).left(86)
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.add_theme_font_size_override("font_size", 13)
	objective.add_theme_color_override("font_color", Color("d7dde3"))
	box.add_child(objective)

	var last_result = str(task.get("last_result", "")).strip_edges()
	if not last_result.is_empty():
		var result = Label.new()
		result.text = "结果：" + last_result.left(70)
		result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		result.add_theme_font_size_override("font_size", 12)
		result.add_theme_color_override("font_color", Color("aeb8c2"))
		box.add_child(result)
	return panel


func _task_row_style(status: String) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	var lower = status.strip_edges().to_lower()
	match lower:
		"running":
			style.bg_color = Color(0.12, 0.18, 0.16, 0.96)
			style.border_color = Color(0.24, 0.85, 0.54, 0.86)
		"completed":
			style.bg_color = Color(0.11, 0.13, 0.15, 0.82)
			style.border_color = Color(0.42, 0.55, 0.62, 0.70)
		"blocked":
			style.bg_color = Color(0.20, 0.11, 0.10, 0.96)
			style.border_color = Color(0.92, 0.38, 0.28, 0.88)
		"cancelled":
			style.bg_color = Color(0.15, 0.13, 0.16, 0.88)
			style.border_color = Color(0.62, 0.50, 0.70, 0.72)
		_:
			style.bg_color = Color(0.11, 0.12, 0.13, 0.94)
			style.border_color = Color(0.52, 0.58, 0.64, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	return style


func _task_status_label(status: String) -> String:
	match status.strip_edges().to_lower():
		"running":
			return "执行中"
		"completed":
			return "已完成"
		"blocked":
			return "受阻"
		"cancelled":
			return "已取消"
		_:
			return "等待"


func _task_tooltip(task: Dictionary) -> String:
	var lines = [
		"%s %s" % [_task_status_label(str(task.get("status", "pending"))), str(task.get("title", ""))],
		"ID: %s" % str(task.get("id", "")),
		"类型: %s" % str(task.get("kind", "general")),
		"优先级: %d" % int(task.get("priority", 5)),
		"目标: %s" % str(task.get("objective", "")),
	]
	var notes = str(task.get("notes", "")).strip_edges()
	if not notes.is_empty():
		lines.append("备注: %s" % notes)
	var last_result = str(task.get("last_result", "")).strip_edges()
	if not last_result.is_empty():
		lines.append("最近结果: %s" % last_result)
	return "\n".join(lines)


func _build_chat() -> void:
	var panel = PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 8
	panel.offset_right = -8
	panel.offset_top = -178
	panel.offset_bottom = -8
	add_child(panel)

	var box = VBoxContainer.new()
	panel.add_child(box)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 118)
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_log)

	var input_row = HBoxContainer.new()
	box.add_child(input_row)

	_input = LineEdit.new()
	_input.placeholder_text = "输入后按 Enter 与 AI 玩家交流"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_submit_message)
	input_row.add_child(_input)

	_send_button = Button.new()
	_send_button.text = "发送"
	_send_button.pressed.connect(func(): _submit_message(_input.text))
	input_row.add_child(_send_button)


func _build_build_inventory_panel() -> void:
	_build_inventory_panel = PanelContainer.new()
	_build_inventory_panel.anchor_left = 0.5
	_build_inventory_panel.anchor_right = 0.5
	_build_inventory_panel.anchor_top = 0.5
	_build_inventory_panel.anchor_bottom = 0.5
	_build_inventory_panel.offset_left = -322
	_build_inventory_panel.offset_top = -230
	_build_inventory_panel.offset_right = 322
	_build_inventory_panel.offset_bottom = 210
	_build_inventory_panel.visible = false
	_build_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.17, 0.17, 0.17, 0.96)
	panel_style.border_color = Color(0.05, 0.05, 0.05, 0.95)
	panel_style.set_border_width_all(3)
	panel_style.set_corner_radius_all(3)
	_build_inventory_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_build_inventory_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 16)
	_build_inventory_panel.add_child(margin)

	_build_inventory_box = VBoxContainer.new()
	_build_inventory_box.add_theme_constant_override("separation", 12)
	margin.add_child(_build_inventory_box)


func _populate_build_inventory(player_inventory: Dictionary, selected_kind: String) -> void:
	for child in _build_inventory_box.get_children():
		_build_inventory_box.remove_child(child)
		child.queue_free()

	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 12)
	_build_inventory_box.add_child(title_row)

	var title = Label.new()
	title.text = "背包"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("f0f0f0"))
	title_row.add_child(title)

	var close_button = Button.new()
	close_button.text = "关闭"
	close_button.custom_minimum_size = Vector2(82, 34)
	close_button.pressed.connect(hide_build_inventory)
	title_row.add_child(close_button)

	var hand_row = HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 12)
	_build_inventory_box.add_child(hand_row)

	var hand_label = Label.new()
	hand_label.text = "主手"
	hand_label.custom_minimum_size = Vector2(58, 58)
	hand_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hand_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hand_label.add_theme_color_override("font_color", Color("d8d8d8"))
	hand_row.add_child(hand_label)

	var hand_entry = _selected_hand_entry(player_inventory, selected_kind)
	if hand_entry.is_empty():
		hand_row.add_child(_inventory_empty_slot("尚未选择主手方块"))
	else:
		hand_row.add_child(_inventory_slot_button(hand_entry, player_inventory, selected_kind, true))

	var empty_hand_button = Button.new()
	empty_hand_button.text = "空手"
	empty_hand_button.custom_minimum_size = Vector2(72, 58)
	empty_hand_button.tooltip_text = "清空主手；空手时仍可用右键拆除方块。"
	empty_hand_button.pressed.connect(func(): main_hand_selected.emit(""))
	hand_row.add_child(empty_hand_button)

	var hand_hint = Label.new()
	hand_hint.text = "按 B 打开/关闭。点击方块格设为主手；点空手后可右键拆除。"
	hand_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hand_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hand_hint.add_theme_color_override("font_color", Color("c7c7c7"))
	hand_row.add_child(hand_hint)

	var grid = GridContainer.new()
	grid.columns = INVENTORY_COLUMNS
	grid.add_theme_constant_override("h_separation", 3)
	grid.add_theme_constant_override("v_separation", 3)
	_build_inventory_box.add_child(grid)

	var entries = _inventory_entries(player_inventory)
	for entry in entries:
		grid.add_child(_inventory_slot_button(entry, player_inventory, selected_kind, false))

	for i in range(max(0, INVENTORY_VISIBLE_SLOTS - entries.size())):
		grid.add_child(_inventory_empty_slot())


func _selected_hand_entry(player_inventory: Dictionary, selected_kind: String) -> Dictionary:
	var normalized = GameConfig.normalize_build_kind(selected_kind)
	if normalized.is_empty() or not GameConfig.BUILDABLE_TILE_KINDS.has(normalized):
		return {}
	var cost = GameConfig.build_cost(normalized)
	var count = _buildable_count(player_inventory, cost)
	return {
		"id": normalized,
		"entry_type": "buildable",
		"label": GameConfig.tile_label(normalized),
		"count": count,
		"cost": cost,
		"available": count > 0,
		"selectable": true,
	}


func _inventory_entries(player_inventory: Dictionary) -> Array:
	var entries = []
	for kind in GameConfig.BUILDABLE_TILE_KINDS:
		var normalized = GameConfig.normalize_build_kind(str(kind))
		var cost = GameConfig.build_cost(normalized)
		var count = _buildable_count(player_inventory, cost)
		entries.append({
			"id": normalized,
			"entry_type": "buildable",
			"label": GameConfig.tile_label(normalized),
			"count": count,
			"cost": cost,
			"available": count > 0,
			"selectable": true,
		})

	var item_ids = []
	for item_id in player_inventory.keys():
		item_ids.append(str(item_id))
	item_ids.sort()
	for item_id in item_ids:
		entries.append({
			"id": item_id,
			"entry_type": "item",
			"label": GameConfig.item_label(item_id),
			"count": int(player_inventory.get(item_id, 0)),
			"available": int(player_inventory.get(item_id, 0)) > 0,
			"selectable": false,
		})
	return entries


func _inventory_slot_button(entry: Dictionary, player_inventory: Dictionary, selected_kind: String, is_hand_slot: bool) -> Button:
	var entry_id = str(entry.get("id", ""))
	var entry_type = str(entry.get("entry_type", "item"))
	var available = bool(entry.get("available", true))
	var selected = is_hand_slot or (entry_type == "buildable" and entry_id == selected_kind)
	var selectable = bool(entry.get("selectable", false))

	var button = Button.new()
	button.text = ""
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = INVENTORY_SLOT_SIZE
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.tooltip_text = _inventory_tooltip(entry, player_inventory, selected, is_hand_slot)
	_apply_inventory_slot_theme(button, selected, available)

	var icon = TextureRect.new()
	icon.texture = _inventory_icon_texture(entry_id, entry_type)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.anchor_left = 0.5
	icon.anchor_right = 0.5
	icon.anchor_top = 0.5
	icon.anchor_bottom = 0.5
	icon.offset_left = -INVENTORY_ICON_SIZE.x * 0.5
	icon.offset_right = INVENTORY_ICON_SIZE.x * 0.5
	icon.offset_top = -INVENTORY_ICON_SIZE.y * 0.5 - 2
	icon.offset_bottom = INVENTORY_ICON_SIZE.y * 0.5 - 2
	button.add_child(icon)

	var glyph = Label.new()
	glyph.text = _inventory_icon_glyph(entry_id, entry_type)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.anchor_left = 0.0
	glyph.anchor_right = 1.0
	glyph.anchor_top = 0.0
	glyph.anchor_bottom = 1.0
	glyph.offset_left = 0
	glyph.offset_right = 0
	glyph.offset_top = -7
	glyph.offset_bottom = -7
	glyph.add_theme_font_size_override("font_size", 18)
	glyph.add_theme_color_override("font_color", Color("f5f1df"))
	button.add_child(glyph)

	var count_label = Label.new()
	count_label.text = str(int(entry.get("count", 0)))
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.anchor_left = 0.0
	count_label.anchor_right = 1.0
	count_label.anchor_top = 0.0
	count_label.anchor_bottom = 1.0
	count_label.offset_left = 4
	count_label.offset_right = -5
	count_label.offset_top = 4
	count_label.offset_bottom = -3
	count_label.add_theme_font_size_override("font_size", 13)
	count_label.add_theme_color_override("font_color", Color("ffffff") if available else Color("9a9a9a"))
	button.add_child(count_label)

	if selectable:
		var kind_copy = entry_id
		if available:
			button.pressed.connect(func(): main_hand_selected.emit(kind_copy))
		else:
			button.pressed.connect(func():
				append_system("材料不足，无法把%s设为主手。" % GameConfig.tile_label(kind_copy))
			)
	return button


func _inventory_empty_slot(tooltip = "") -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = INVENTORY_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP if not str(tooltip).is_empty() else Control.MOUSE_FILTER_IGNORE
	slot.tooltip_text = str(tooltip)
	slot.add_theme_stylebox_override("panel", _inventory_slot_style(false, false, false, true))
	return slot


func _apply_inventory_slot_theme(button: Button, selected: bool, available: bool) -> void:
	button.add_theme_stylebox_override("normal", _inventory_slot_style(selected, available, false))
	button.add_theme_stylebox_override("hover", _inventory_slot_style(selected, available, true))
	button.add_theme_stylebox_override("pressed", _inventory_slot_style(selected, available, true))
	button.add_theme_color_override("font_color", Color(1, 1, 1, 0))
	button.add_theme_color_override("font_hover_color", Color(1, 1, 1, 0))
	button.add_theme_color_override("font_pressed_color", Color(1, 1, 1, 0))
	button.add_theme_color_override("font_focus_color", Color(1, 1, 1, 0))


func _inventory_slot_style(selected: bool, available: bool, hover: bool, empty = false) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	if empty:
		style.bg_color = Color(0.10, 0.10, 0.10, 0.88)
		style.border_color = Color(0.32, 0.32, 0.32, 0.78)
	elif selected:
		style.bg_color = Color(0.26, 0.23, 0.13, 0.96) if not hover else Color(0.34, 0.29, 0.15, 0.98)
		style.border_color = Color(0.98, 0.78, 0.22, 1.0)
	elif available:
		style.bg_color = Color(0.25, 0.25, 0.25, 0.96) if not hover else Color(0.32, 0.32, 0.32, 0.98)
		style.border_color = Color(0.62, 0.62, 0.62, 0.95)
	else:
		style.bg_color = Color(0.13, 0.13, 0.13, 0.92) if not hover else Color(0.18, 0.18, 0.18, 0.96)
		style.border_color = Color(0.36, 0.36, 0.36, 0.78)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(2)
	return style


func _inventory_tooltip(entry: Dictionary, player_inventory: Dictionary, selected: bool, is_hand_slot: bool) -> String:
	var entry_id = str(entry.get("id", ""))
	var entry_type = str(entry.get("entry_type", "item"))
	var lines = []
	lines.append(str(entry.get("label", entry_id)))
	lines.append("ID: %s" % entry_id)
	if selected:
		lines.append("当前主手" if is_hand_slot else "已选为主手")
	if entry_type == "buildable":
		var cost: Dictionary = entry.get("cost", {})
		lines.append("类型：建造方块")
		lines.append("可建造数量：%d" % int(entry.get("count", 0)))
		lines.append("消耗：%s" % _build_item_stack_text(cost))
		lines.append("持有：%s" % _inventory_owned_text(player_inventory, cost))
		if GameConfig.WATER_BUILDABLE_TILE_KINDS.has(entry_id):
			lines.append("可直接建造在水上。")
		else:
			lines.append("不能直接建造在水上。")
		lines.append("左键点击设为主手。")
		if int(entry.get("count", 0)) <= 0:
			lines.append("材料不足。")
	else:
		lines.append("类型：材料")
		lines.append("数量：%d" % int(entry.get("count", 0)))
		lines.append("用于建造、修补或之后的制作系统。")
	return "\n".join(lines)


func _buildable_count(inventory: Dictionary, cost: Dictionary) -> int:
	if cost.is_empty():
		return 0
	var count = 2147483647
	for item_id in cost.keys():
		var required = max(1, int(cost[item_id]))
		count = min(count, int(floor(float(inventory.get(item_id, 0)) / float(required))))
	return max(0, count)


func _inventory_icon_texture(entry_id: String, entry_type: String) -> Texture2D:
	var cache_key = "%s:%s" % [entry_type, entry_id]
	if _inventory_icon_cache.has(cache_key):
		return _inventory_icon_cache[cache_key]

	var image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var base = _inventory_icon_base_color(entry_id, entry_type)
	for y in range(32):
		for x in range(32):
			var color = base
			var edge = x < 2 or y < 2 or x >= 30 or y >= 30
			if edge:
				color = base.darkened(0.38)
			elif entry_id == "wood_floor":
				if x % 8 == 0 or y == 15:
					color = base.darkened(0.22)
				elif (x + y) % 11 == 0:
					color = base.lightened(0.12)
			elif entry_id == "wood_wall" or entry_id == "wood":
				if x % 7 <= 1:
					color = base.darkened(0.24)
				elif (x * 3 + y) % 13 == 0:
					color = base.lightened(0.12)
			elif entry_id == "stone_floor" or entry_id == "stone":
				if (x * 13 + y * 7) % 17 == 0:
					color = base.lightened(0.18)
				elif (x * 5 + y * 11) % 19 == 0:
					color = base.darkened(0.18)
			image.set_pixel(x, y, color)

	var texture = ImageTexture.create_from_image(image)
	_inventory_icon_cache[cache_key] = texture
	return texture


func _inventory_icon_base_color(entry_id: String, entry_type: String) -> Color:
	match entry_id:
		"wood", "wood_floor":
			return Color("9b6231")
		"wood_wall":
			return Color("6f4326")
		"stone", "stone_floor":
			return Color("777b82")
		_:
			return Color("5c738c") if entry_type == "buildable" else Color("8a845b")


func _inventory_icon_glyph(entry_id: String, entry_type: String) -> String:
	match entry_id:
		"wood":
			return "木"
		"stone":
			return "石"
		"wood_floor":
			return "板"
		"stone_floor":
			return "砖"
		"wood_wall":
			return "墙"
		_:
			return "方" if entry_type == "buildable" else "物"


func _make_custom_tooltip(for_text: String) -> Object:
	var tooltip_text = for_text.strip_edges()
	if tooltip_text.is_empty():
		return null

	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(260, 0)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.05, 0.96)
	style.border_color = Color(0.72, 0.72, 0.72, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	panel.add_theme_stylebox_override("panel", style)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var label = Label.new()
	label.text = tooltip_text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color("f2f2f2"))
	label.add_theme_font_size_override("font_size", 14)
	margin.add_child(label)
	return panel


func _build_ai_dialogue_popup() -> void:
	_dialogue_panel = PanelContainer.new()
	_dialogue_panel.anchor_left = 0.06
	_dialogue_panel.anchor_right = 0.94
	_dialogue_panel.anchor_top = 0.0
	_dialogue_panel.anchor_bottom = 0.0
	_dialogue_panel.offset_top = 86
	_dialogue_panel.offset_bottom = 214
	_dialogue_panel.visible = false
	_dialogue_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialogue_panel.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed:
			_dialogue_panel.visible = false
			_dialogue_timer.stop()
	)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.07, 0.045, 0.06, 0.92)
	panel_style.border_color = Color(0.42, 0.35, 0.43, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(6)
	_dialogue_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_dialogue_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 14)
	_dialogue_panel.add_child(margin)

	var row = HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 22)
	margin.add_child(row)

	_dialogue_portrait = PortraitViewScene.new()
	_dialogue_portrait.custom_minimum_size = Vector2(96, 96)
	_dialogue_portrait.set_portrait_dir(DEFAULT_AI_PORTRAIT_DIR)
	_dialogue_portrait.set_character(true, "calm")
	row.add_child(_dialogue_portrait)

	_dialogue_label = Label.new()
	_dialogue_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dialogue_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_dialogue_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_label.add_theme_font_size_override("font_size", 30)
	_dialogue_label.add_theme_color_override("font_color", Color("ebe6ea"))
	row.add_child(_dialogue_label)

	var arrow = Label.new()
	arrow.text = "▼"
	arrow.custom_minimum_size = Vector2(28, 0)
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	arrow.add_theme_font_size_override("font_size", 22)
	arrow.add_theme_color_override("font_color", Color("ebe6ea"))
	row.add_child(arrow)

	_dialogue_timer = Timer.new()
	_dialogue_timer.one_shot = true
	_dialogue_timer.timeout.connect(func(): _dialogue_panel.visible = false)
	add_child(_dialogue_timer)


func _build_setup_panel() -> void:
	_setup_overlay = CenterContainer.new()
	_setup_overlay.anchor_right = 1.0
	_setup_overlay.anchor_bottom = 1.0
	_setup_overlay.offset_left = 0
	_setup_overlay.offset_top = 0
	_setup_overlay.offset_right = 0
	_setup_overlay.offset_bottom = 0
	_setup_overlay.visible = false
	_setup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_setup_overlay)

	_setup_panel = PanelContainer.new()
	_setup_panel.custom_minimum_size = Vector2(760, 420)
	_setup_overlay.add_child(_setup_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	_setup_panel.add_child(margin)

	_setup_box = VBoxContainer.new()
	_setup_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_setup_box.add_theme_constant_override("separation", 12)
	margin.add_child(_setup_box)


func _show_new_save_menu() -> void:
	_clear_setup_box()
	_add_title("新建存档")
	_build_resolution_selector()

	var name_input = LineEdit.new()
	name_input.placeholder_text = "存档名称"
	name_input.text = "新的生活"
	name_input.custom_minimum_size = Vector2(600, 40)
	_setup_box.add_child(name_input)

	var player_option = _build_option_row("初始技能属性", _cached_player_presets, "name", "description")
	var ai_option = _build_option_row("AI角色", _cached_ai_roles, "name", "description")

	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	_setup_box.add_child(row)

	var create_button = Button.new()
	create_button.text = "创建"
	create_button.custom_minimum_size = Vector2(160, 42)
	create_button.pressed.connect(func():
		_select_new_save(name_input.text, player_option, ai_option)
	)
	row.add_child(create_button)

	var back_button = Button.new()
	back_button.text = "返回"
	back_button.custom_minimum_size = Vector2(160, 42)
	back_button.pressed.connect(func():
		show_start_menu(_cached_saves, _cached_player_presets, _cached_ai_roles)
	)
	row.add_child(back_button)


func _build_option_row(label_text: String, items: Array, name_key: String, description_key: String) -> OptionButton:
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_setup_box.add_child(row)

	var label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120, 38)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var option = OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(option)

	for item in items:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var index = option.item_count
		var text = str(item.get(name_key, "未命名"))
		var description = str(item.get(description_key, ""))
		if not description.is_empty():
			text += " - " + description.left(60)
		option.add_item(text)
		option.set_item_metadata(index, item)
	if option.item_count > 0:
		option.select(0)
	return option


func _select_new_save(save_name: String, player_option: OptionButton, ai_option: OptionButton) -> void:
	var player_preset = player_option.get_item_metadata(max(player_option.selected, 0))
	var ai_role = ai_option.get_item_metadata(max(ai_option.selected, 0))
	if typeof(player_preset) != TYPE_DICTIONARY or typeof(ai_role) != TYPE_DICTIONARY:
		return
	_setup_overlay.visible = false
	new_save_requested.emit({
		"save_name": save_name.strip_edges(),
		"player_preset": player_preset,
		"ai_role": ai_role,
	})


func _select_load_save(save: Dictionary) -> void:
	var save_id = str(save.get("save_id", ""))
	if save_id.is_empty():
		return
	_setup_overlay.visible = false
	load_save_requested.emit(save_id)


func _select_exit_choice(choice: String) -> void:
	if choice == "cancel":
		_setup_overlay.visible = false
	exit_choice_selected.emit(choice)


func _submit_message(text: String) -> void:
	var trimmed = text.strip_edges()
	if trimmed.is_empty() or not _input.editable:
		return
	_input.clear()
	append_chat("你：", trimmed, "#f0c36a")
	message_submitted.emit(trimmed)


func _inventory_has_items(inventory: Dictionary, cost: Dictionary) -> bool:
	for item_id in cost.keys():
		if int(inventory.get(item_id, 0)) < int(cost[item_id]):
			return false
	return true


func _inventory_owned_text(inventory: Dictionary, cost: Dictionary) -> String:
	if cost.is_empty():
		return "无"
	var parts = []
	for item_id in cost.keys():
		parts.append("%s %d/%d" % [
			GameConfig.item_label(str(item_id)),
			int(inventory.get(item_id, 0)),
			int(cost[item_id]),
		])
	return "、".join(parts)


func _build_item_stack_text(items: Dictionary) -> String:
	if items.is_empty():
		return "无"
	var parts = []
	for item_id in items.keys():
		parts.append("%s x%d" % [GameConfig.item_label(str(item_id)), int(items[item_id])])
	return "、".join(parts)


func _build_resolution_selector() -> void:
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_setup_box.add_child(row)

	var label = Label.new()
	label.text = "启动分辨率"
	label.custom_minimum_size = Vector2(120, 36)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_resolution_option = OptionButton.new()
	_resolution_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_resolution_option)

	var current_size = DisplayServer.window_get_size()
	var selected_index = 0
	for size in GameConfig.RESOLUTION_OPTIONS:
		var index = _resolution_option.item_count
		_resolution_option.add_item("%d x %d" % [size.x, size.y])
		_resolution_option.set_item_metadata(index, size)
		if size == current_size:
			selected_index = index
	_resolution_option.select(selected_index)
	_resolution_option.item_selected.connect(_on_resolution_item_selected)


func _on_resolution_item_selected(index: int) -> void:
	var size = _resolution_option.get_item_metadata(index)
	if typeof(size) == TYPE_VECTOR2I:
		resolution_selected.emit(size)


func _add_title(text: String) -> void:
	var title = Label.new()
	title.text = text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(0, 42)
	title.add_theme_font_size_override("font_size", 24)
	_setup_box.add_child(title)


func _add_button(text: String, callback: Callable) -> Button:
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(650, 44)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	_setup_box.add_child(button)
	return button


func _clear_setup_box() -> void:
	for child in _setup_box.get_children():
		child.queue_free()


func _fill_viewport() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
