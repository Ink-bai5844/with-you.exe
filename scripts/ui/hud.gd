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

var _status_label: Label
var _log: RichTextLabel
var _input: LineEdit
var _send_button: Button
var _save_button: Button
var _exit_button: Button
var _debug_overlay_panel: PanelContainer
var _debug_overlay_label: Label
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


func _ready() -> void:
	_fill_viewport()
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_status()
	_build_debug_overlay()
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


func set_status(clock_snapshot: Dictionary, player_state: Dictionary, ai_state: Dictionary, llm_ready: bool) -> void:
	var player_name = player_state.get("name", "玩家")
	var ai_name = ai_state.get("name", "AI")
	var player_attr: Dictionary = player_state.get("attributes", {})
	var ai_attr: Dictionary = ai_state.get("attributes", {})
	var player_inventory: Dictionary = player_state.get("inventory", {})
	var ai_inventory: Dictionary = ai_state.get("inventory", {})
	var ai_mood = str(ai_state.get("mood", "calm"))
	var status_text = "时间 %s | LLM %s | %s HP:%s EN:%s 木:%s 石:%s | %s 心情:%s HP:%s EN:%s 木:%s 石:%s" % [
		clock_snapshot.get("game_time", "--:--"),
		"在线" if llm_ready else "离线占位",
		player_name,
		player_attr.get("health", "-"),
		player_attr.get("energy", "-"),
		player_inventory.get("wood", 0),
		player_inventory.get("stone", 0),
		ai_name,
		ai_mood,
		ai_attr.get("health", "-"),
		ai_attr.get("energy", "-"),
		ai_inventory.get("wood", 0),
		ai_inventory.get("stone", 0),
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
	_build_inventory_panel.anchor_left = 0.0
	_build_inventory_panel.anchor_right = 0.0
	_build_inventory_panel.anchor_top = 0.0
	_build_inventory_panel.anchor_bottom = 0.0
	_build_inventory_panel.offset_left = 12
	_build_inventory_panel.offset_top = 86
	_build_inventory_panel.offset_right = 344
	_build_inventory_panel.offset_bottom = 350
	_build_inventory_panel.visible = false
	_build_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.06, 0.07, 0.08, 0.92)
	panel_style.border_color = Color(0.36, 0.48, 0.56, 0.9)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(6)
	_build_inventory_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_build_inventory_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_build_inventory_panel.add_child(margin)

	_build_inventory_box = VBoxContainer.new()
	_build_inventory_box.add_theme_constant_override("separation", 8)
	margin.add_child(_build_inventory_box)


func _populate_build_inventory(player_inventory: Dictionary, selected_kind: String) -> void:
	for child in _build_inventory_box.get_children():
		_build_inventory_box.remove_child(child)
		child.queue_free()

	var title = Label.new()
	title.text = "背包：选择主手方块"
	title.add_theme_font_size_override("font_size", 17)
	_build_inventory_box.add_child(title)

	for kind in GameConfig.BUILDABLE_TILE_KINDS:
		var normalized = GameConfig.normalize_build_kind(str(kind))
		var cost = GameConfig.build_cost(normalized)
		var button = Button.new()
		var selected_mark = "● " if normalized == selected_kind else ""
		button.text = "%s%s  需要 %s  持有 %s" % [
			selected_mark,
			GameConfig.tile_label(normalized),
			_build_item_stack_text(cost),
			_inventory_owned_text(player_inventory, cost),
		]
		button.custom_minimum_size = Vector2(0, 40)
		button.disabled = not _inventory_has_items(player_inventory, cost)
		var kind_copy = normalized
		button.pressed.connect(func(): main_hand_selected.emit(kind_copy))
		_build_inventory_box.add_child(button)

	var hint = Label.new()
	hint.text = "选中后：鼠标左键建造，右键拆除；ESC 退出建造。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color("aeb8c2")
	_build_inventory_box.add_child(hint)

	var close_button = Button.new()
	close_button.text = "关闭"
	close_button.custom_minimum_size = Vector2(0, 36)
	close_button.pressed.connect(hide_build_inventory)
	_build_inventory_box.add_child(close_button)


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
