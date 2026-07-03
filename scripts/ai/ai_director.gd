class_name AIDirector
extends Node

signal ai_spoke(text, mood)
signal thinking_changed(active)
signal debug_event(text)

const GameConfig = preload("res://scripts/config/game_config.gd")
const AI_PROMPT_PATH = "res://config/ai_prompt.json"

var world
var player
var ai
var memory
var llm
var clock
var game_api

var started = false
var busy = false
var next_perception_minutes = 0.0
var next_forget_minutes = 0.0
var queued_player_messages: Array[String] = []
var queued_player_marked_areas: Array = []
var queued_ai_events: Array = []
var ai_prompt = {}

var _pending_brain = {}
var _pending_compression = {}


func setup(new_world, new_player, new_ai, new_memory, new_llm, new_clock, new_game_api) -> void:
	_load_ai_prompt()
	world = new_world
	player = new_player
	ai = new_ai
	memory = new_memory
	llm = new_llm
	clock = new_clock
	game_api = new_game_api
	llm.completion_ready.connect(_on_llm_completed)
	llm.completion_failed.connect(_on_llm_failed)
	if ai.has_signal("action_event"):
		ai.action_event.connect(_on_ai_action_event)
	_apply_prompt_to_ai_profile()


func set_ai_prompt(prompt: Dictionary) -> void:
	ai_prompt = _default_ai_prompt()
	for key in prompt.keys():
		ai_prompt[key] = prompt[key]
	_apply_prompt_to_ai_profile()


func get_ai_prompt() -> Dictionary:
	return ai_prompt.duplicate(true)


func begin() -> void:
	started = true
	next_perception_minutes = clock.game_minutes + _perception_interval()
	next_forget_minutes = clock.game_minutes + _forget_interval()
	debug_event.emit("AI director started.")


func stop() -> void:
	started = false
	busy = false
	queued_player_messages.clear()
	queued_player_marked_areas.clear()
	queued_ai_events.clear()
	_pending_brain.clear()
	_pending_compression.clear()
	thinking_changed.emit(false)


func get_save_data() -> Dictionary:
	return {
		"started": started,
		"next_perception_minutes": next_perception_minutes,
		"next_forget_minutes": next_forget_minutes,
		"ai_prompt": ai_prompt.duplicate(true),
	}


func apply_save_data(data: Dictionary) -> void:
	if typeof(data.get("ai_prompt", null)) == TYPE_DICTIONARY:
		set_ai_prompt(data["ai_prompt"])
	started = bool(data.get("started", true))
	next_perception_minutes = float(data.get("next_perception_minutes", clock.game_minutes + _perception_interval()))
	next_forget_minutes = float(data.get("next_forget_minutes", clock.game_minutes + _forget_interval()))
	busy = false
	queued_player_messages.clear()
	queued_player_marked_areas.clear()
	queued_ai_events.clear()
	_pending_brain.clear()
	_pending_compression.clear()
	thinking_changed.emit(false)


func on_player_message(text: String, player_marked_area: Dictionary = {}) -> void:
	var trimmed = text.strip_edges()
	if trimmed.is_empty():
		return
	queued_player_messages.append(trimmed)
	if not player_marked_area.is_empty():
		queued_player_marked_areas.append(player_marked_area.duplicate(true))
	_request_perception("player_message")


func _on_ai_action_event(event: Dictionary) -> void:
	var sanitized = _sanitize_ai_event(event)
	queued_ai_events.append(sanitized)
	if _ai_action_event_should_trigger_perception(sanitized):
		_request_perception("ai_action_event")


func _process(_delta: float) -> void:
	if not started:
		return
	if clock.game_minutes >= next_forget_minutes:
		var deleted = memory.forget_low_priority_percent(_forget_percent(), clock.game_minutes)
		next_forget_minutes = clock.game_minutes + _forget_interval()
		if not deleted.is_empty():
			debug_event.emit("Forgot memories: %s" % [deleted])

	if clock.game_minutes >= next_perception_minutes:
		next_perception_minutes = clock.game_minutes + _perception_interval()
		_request_perception("auto_interval")


func _request_perception(trigger: String) -> void:
	if busy:
		return

	busy = true
	thinking_changed.emit(true)
	var player_messages = queued_player_messages.duplicate()
	var player_marked_areas = queued_player_marked_areas.duplicate(true)
	var ai_events = queued_ai_events.duplicate(true)
	queued_player_messages.clear()
	queued_player_marked_areas.clear()
	queued_ai_events.clear()
	var snapshot = _build_perception(trigger, player_messages, ai_events, player_marked_areas)

	if llm.is_configured():
		var request_id = llm.chat(_brain_messages(snapshot), {"json_response": true, "temperature": 0.35})
		_pending_brain[request_id] = snapshot
	else:
		_apply_ai_response(_offline_brain(snapshot), snapshot)


func _build_perception(trigger: String, player_messages: Array, ai_events: Array, player_marked_areas: Array) -> Dictionary:
	var player_tile = world.world_to_tile(player.global_position)
	var ai_tile = world.world_to_tile(ai.global_position)
	var memories = memory.recall(_memory_recall_count(), clock.game_minutes)
	var activation = _build_activation(trigger, player_messages, ai_events, player_marked_areas)
	return {
		"trigger": trigger,
		"activation": activation,
		"player_messages": player_messages,
		"player_marked_areas": player_marked_areas,
		"player_marked_area": player_marked_areas[0] if player_marked_areas.size() == 1 else {},
		"ai_events": ai_events,
		"map": world.encode_area_size(ai_tile, _perception_map_tile_size()),
		"map_rays": world.encode_rays(ai_tile, _perception_ray_tile_length()),
		"visible_entities": [
			{"id": "player", "kind": "real_player", "tile": [player_tile.x, player_tile.y], "state": player.get_state()},
			{"id": "ai", "kind": "ai_player", "tile": [ai_tile.x, ai_tile.y], "state": ai.get_state()},
		],
		"player": player.get_state(),
		"ai": ai.get_state(),
		"game_time": clock.snapshot(),
		"system_time": Time.get_datetime_string_from_system(false, true),
		"recent_history": memory.recent_history_for_prompt(),
		"historical_memories": memories,
		"runtime_api": game_api.snapshot(),
	}


func _build_activation(trigger: String, player_messages: Array, ai_events: Array, player_marked_areas: Array) -> Dictionary:
	var has_player_messages = not player_messages.is_empty()
	var has_player_marked_areas = not player_marked_areas.is_empty()
	var is_player_initiated = trigger == "player_message" or trigger == "queued_player_message" or has_player_messages or has_player_marked_areas
	var is_ai_action_event = trigger == "ai_action_event" or trigger == "queued_ai_action_event" or (not ai_events.is_empty() and not is_player_initiated)
	var is_automatic_perception = trigger == "auto_interval" and not is_player_initiated and not is_ai_action_event

	var source = "auto_perception"
	if is_player_initiated:
		source = "player_interaction"
	elif is_ai_action_event:
		source = "ai_action_event"

	var should_consider_reply = is_player_initiated or _ai_events_suggest_reply(ai_events)
	var reply_policy = "Background automatic perception. Usually return talk_to_player=false and dialogue=\"\"; keep thinking, memory, and actions internal unless there is an important discovery, urgent need, danger, or task result the player should know."
	if is_player_initiated:
		reply_policy = "Player actively sent a message. Usually answer with talk_to_player=true unless the message requires only silent action."
		if has_player_marked_areas:
			reply_policy += " The player also actively marked map area(s) with the mouse; treat player_marked_areas as explicit player-directed focus and use them when interpreting the message."
	elif is_ai_action_event:
		reply_policy = "Triggered by your own action result. Reply only if the event is useful for the player to know, such as finding a target, failing a search, or completing an assigned task."

	return {
		"trigger": trigger,
		"source": source,
		"is_player_initiated": is_player_initiated,
		"is_automatic_perception": is_automatic_perception,
		"is_ai_action_event": is_ai_action_event,
		"player_message_count": player_messages.size(),
		"player_marked_area_count": player_marked_areas.size(),
		"has_player_marked_area": has_player_marked_areas,
		"player_marked_area_source": "player_mouse_rectangle_selection" if has_player_marked_areas else "",
		"ai_event_count": ai_events.size(),
		"should_consider_reply": should_consider_reply,
		"reply_policy": reply_policy,
	}


func _ai_events_suggest_reply(ai_events: Array) -> bool:
	for event in ai_events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var event_type = str(event.get("event_type", ""))
		var status = str(event.get("status", ""))
		if event_type in ["search_target_found", "search_failed", "action_completed", "action_interrupted", "gather_completed", "gather_failed"]:
			return true
		if status in ["found", "failed", "completed"]:
			return true
	return false


func _ai_action_event_should_trigger_perception(event: Dictionary) -> bool:
	var batch_count = int(event.get("batch_count", 1))
	var batch_index = int(event.get("batch_index", batch_count))
	var event_type = str(event.get("event_type", ""))
	var status = str(event.get("status", ""))
	if batch_count > 1 and event_type in ["build_completed", "destroy_completed"] and status == "completed":
		return batch_index >= batch_count
	return true


func _brain_messages(snapshot: Dictionary) -> Array:
	return [
		{
			"role": "system",
			"content": _build_system_prompt()
		},
		{
			"role": "user",
			"content": JSON.stringify(snapshot)
		}
	]


func _build_system_prompt() -> String:
	var profile_lines = [
		"Character name: %s" % str(ai_prompt.get("character_name", "悠")),
		"Role: %s" % str(ai_prompt.get("role", "AI player and companion in a 2D pixel sandbox life game.")),
		"Background: %s" % str(ai_prompt.get("background", "")),
		"Personality: %s" % _prompt_list(ai_prompt.get("personality", [])),
		"Speaking style: %s" % str(ai_prompt.get("speaking_style", "")),
		"Relationship to player: %s" % str(ai_prompt.get("relationship_to_player", "")),
		"Extra rules: %s" % str(ai_prompt.get("extra_system_prompt", "")),
	]
	var mood_values = "|".join(GameConfig.MOODS)
	var protocol = "Return only JSON. Schema: {\"talk_to_player\":bool,\"dialogue\":string,\"has_action\":bool,\"action\":object,\"set_follow\":-1|0|1,\"mood\":\"%s\",\"thought\":string,\"memory_ops\":{\"add\":[{\"summary\":string,\"priority\":int}],\"update_priority\":[{\"id\":int,\"priority\":int}],\"delete\":[int]}}. set_follow controls persistent follow state: -1 unchanged, 0 stop following the player, 1 follow the player. The default follow state is off. Supported actions: {\"type\":\"move_to_tile\",\"tile\":[x,y]} moves directly; {\"type\":\"path_to_tile\",\"tile\":[x,y],\"avoid\":[\"water\",\"wood_wall\",\"tree\",\"stone_hill\"]} pathfinds through nearby tiles while avoiding listed terrain; {\"type\":\"search_for_tile\",\"target\":\"water|grass|plain|tree|stone_hill|city|city_border|wood_floor|stone_floor|wood_wall\",\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8,\"avoid\":[]} keeps walking and scanning until that terrain is found or steps run out; {\"type\":\"wander\",\"radius\":16,\"steps\":8,\"step_tiles\":8,\"avoid\":[\"water\"]} explores around the current area; {\"type\":\"gather_resource\",\"resource\":\"wood|stone\",\"amount\":1,\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8} searches for a matching resource source, walks adjacent, destroys it, and adds drops to your inventory; {\"type\":\"build_tile\",\"tile\":[x,y],\"tile_kind\":\"wood_floor|stone_floor|wood_wall\"} builds one tile using your inventory; {\"type\":\"build_tiles\",\"tile_kind\":\"wood_floor|stone_floor|wood_wall\",\"tiles\":[[x,y],[x,y]]} builds many same-kind tiles; {\"type\":\"build_tiles\",\"placements\":[{\"tile\":[x,y],\"tile_kind\":\"wood_floor\"},{\"tile\":[x,y],\"tile_kind\":\"wood_wall\"}]} builds many mixed-kind tiles; {\"type\":\"destroy_tile\",\"tile\":[x,y]} removes one built tile or destroys a tree/stone_hill terrain tile and recovers materials; {\"type\":\"destroy_tiles\",\"tiles\":[[x,y],[x,y]]} removes many built tiles, trees, or stone hills; {\"type\":\"follow_player\"} moves near the player once; {\"type\":\"idle\"} stops. Player and AI state include inventory; build costs are wood_floor=1 wood, stone_floor=1 stone, wood_wall=2 wood. Water is not walkable in normal mode; wood_floor can be built directly on water to make a walkable bridge. Destroying tree terrain yields wood; destroying stone_hill yields stone. Use gather_resource when you want to collect resources proactively instead of only searching. The automaton will execute batch build/destroy tasks one by one; you can return many planned tiles at once. The perception may include ai_events such as search_target_found, search_failed, action_completed, build_completed, build_failed, destroy_completed, destroy_failed, gather_progress, gather_completed, gather_failed, or movement_unstuck_teleport. Batch events include batch_id, batch_index, and batch_count. Treat these events as your own new observation: acknowledge important discoveries, remember useful findings, and choose the next action if needed. If the player asks you to follow or stop following, return set_follow accordingly. If you say you will go somewhere, search, build, gather, or destroy something, set has_action=true and return an executable action. The map rows are centered on your current tile and limited by the configured perception map size; use the origin and legend. map_rays contains eight compass rays from your tile, up to the configured ray length, and may see beyond the screen; each ray reports only the earliest position and attributes for each new tile kind encountered along that direction. W means river water, T tree, H stone hill, F wood floor, S stone floor, X wood wall. Do not only promise movement, gathering, or building in dialogue. You may update/delete recalled memories by id." % mood_values
	var interrupt_protocol = "Pathfinding and long actions are interruptible. If the player asks you to stop, cancel, wait, interrupt the current route, or abandon a task, return has_action=true and action {\"type\":\"interrupt_action\",\"reason\":\"player_request\"}. If the player gives a new urgent destination/task that should replace the old one, include \"interrupt_current\":true on the new action instead of queueing behind the old path."
	var activation_protocol = "The snapshot includes activation. activation.source is one of player_interaction, auto_perception, or ai_action_event. If activation.is_player_initiated is true, the player actively spoke to you; normally answer the player. If activation.is_automatic_perception is true, this is a background sensing tick; normally keep talk_to_player=false and dialogue=\"\" unless the situation is important enough to interrupt the player. If activation.is_ai_action_event is true, respond only when your action result matters to the player. Use activation.reply_policy and activation.should_consider_reply when deciding whether to return dialogue; you may still return actions, mood, thought, and memory_ops without speaking."
	var player_mark_protocol = "The snapshot may include player_marked_areas. These are rectangular map regions that the human player actively selected with the mouse before sending the current message. Treat them as explicit player-directed context or pointing gestures, not automatic perception. Each marked area contains selected_rect, rows, legend, counts, and notable_tiles."
	return "\n".join(profile_lines) + "\n\n" + protocol + "\n" + interrupt_protocol + "\n" + activation_protocol + "\n" + player_mark_protocol


func _prompt_list(value) -> String:
	if typeof(value) == TYPE_ARRAY:
		var items = []
		for item in value:
			items.append(str(item))
		return "、".join(items)
	return str(value)


func _load_ai_prompt() -> void:
	ai_prompt = _default_ai_prompt()
	if not FileAccess.file_exists(AI_PROMPT_PATH):
		return
	var file = FileAccess.open(AI_PROMPT_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for key in parsed.keys():
		ai_prompt[key] = parsed[key]


func _default_ai_prompt() -> Dictionary:
	return {
		"character_name": "悠",
		"role": "AI player and companion in a 2D pixel sandbox life game.",
		"background": "You and the human player have arrived in a simple sandbox world with a central city area, grass, plains, rivers, trees, and rocky hills.",
		"personality": ["gentle", "curious", "observant", "proactive"],
		"speaking_style": "Speak concise, natural Chinese as an in-world companion.",
		"relationship_to_player": "The player is your companion for living, exploring, and developing the world together.",
		"extra_system_prompt": "",
	}


func _apply_prompt_to_ai_profile() -> void:
	if ai == null:
		return
	var character_name = str(ai_prompt.get("character_name", "")).strip_edges()
	if not character_name.is_empty():
		ai.profile["name"] = character_name
	var role = str(ai_prompt.get("role", "")).strip_edges()
	if not role.is_empty():
		ai.profile["description"] = role


func _compression_messages(payload: Dictionary, fallback: String) -> Array:
	return [
		{
			"role": "system",
			"content": "Compress this game interaction and AI thought into one concise Chinese memory line under 120 characters. Return only JSON: {\"summary\":string}."
		},
		{
			"role": "user",
			"content": JSON.stringify({"payload": payload, "fallback": fallback})
		}
	]


func _apply_ai_response(response: Dictionary, snapshot: Dictionary) -> void:
	var mood = str(response.get("mood", "calm"))
	ai.set_mood(mood)

	var follow_signal = _follow_signal_from_response(response)
	if follow_signal != -1:
		ai.set_follow_enabled(follow_signal == 1)

	var memory_ops = response.get("memory_ops", {})
	if typeof(memory_ops) == TYPE_DICTIONARY:
		memory.apply_ai_memory_ops(memory_ops, clock.game_minutes)

	if bool(response.get("has_action", false)):
		var action = _action_from_response(response, snapshot)
		if not action.is_empty():
			ai.enqueue_action(action)
	else:
		var inferred_action = _infer_action_from_context(snapshot, response)
		if not inferred_action.is_empty():
			response["has_action"] = true
			response["action"] = inferred_action
			ai.enqueue_action(inferred_action)

	var dialogue = str(response.get("dialogue", "")).strip_edges()
	if bool(response.get("talk_to_player", false)) and not dialogue.is_empty():
		ai_spoke.emit(dialogue, mood)

	var fallback_summary = _local_summary(snapshot, response)
	var compression_payload = _compact_interaction_payload(snapshot, response)
	if llm.is_configured():
		var request_id = llm.chat(_compression_messages(compression_payload, fallback_summary), {
			"json_response": true,
			"temperature": 0.1,
			"model": llm.compression_model,
		})
		_pending_compression[request_id] = {
			"fallback": fallback_summary,
			"payload": compression_payload,
			"game_minutes": clock.game_minutes,
		}
	else:
		memory.add_recent(fallback_summary, "interaction", clock.game_minutes, compression_payload)

	_finish_brain_cycle()


func _finish_brain_cycle() -> void:
	busy = false
	thinking_changed.emit(false)
	if not queued_player_messages.is_empty() or not queued_player_marked_areas.is_empty():
		_request_perception("queued_player_message")
	elif not queued_ai_events.is_empty():
		_request_perception("queued_ai_action_event")


func _offline_brain(snapshot: Dictionary) -> Dictionary:
	var player_messages: Array = snapshot.get("player_messages", [])
	var player_marked_areas: Array = snapshot.get("player_marked_areas", [])
	var response = {
		"talk_to_player": false,
		"dialogue": "",
		"has_action": false,
		"action": {"type": "idle"},
		"set_follow": -1,
		"mood": "calm",
		"thought": "No LLM key is configured, so I am using the local fallback behavior.",
		"memory_ops": {"add": [], "update_priority": [], "delete": []},
	}
	if not player_messages.is_empty():
		var joined = " / ".join(player_messages)
		response["talk_to_player"] = true
		response["dialogue"] = "我听到了：%s。我们先观察附近，再一起决定下一步。" % joined.left(80)
		if not player_marked_areas.is_empty():
			response["dialogue"] += " 你框选的区域信息我也收到了。"
		response["mood"] = "curious"
		response["memory_ops"]["add"].append({
			"summary": "玩家说：" + joined.left(80),
			"priority": 4,
		})
	return response


func _sanitize_ai_event(event: Dictionary) -> Dictionary:
	return {
		"event_type": str(event.get("event_type", "")),
		"action_type": str(event.get("action_type", "")),
		"target": str(event.get("target", "")),
		"tile_kind": str(event.get("tile_kind", "")),
		"status": str(event.get("status", "")),
		"source": str(event.get("source", "")),
		"found_tile": _small_int_array(event.get("found_tile", []), 2),
		"target_tile": _small_int_array(event.get("target_tile", []), 2),
		"from_tile": _small_int_array(event.get("from_tile", []), 2),
		"to_tile": _small_int_array(event.get("to_tile", []), 2),
		"ai_tile": _small_int_array(event.get("ai_tile", []), 2),
		"ai_position": _small_float_array(event.get("ai_position", []), 2),
		"reason": str(event.get("reason", "")),
		"item_cost": event.get("item_cost", {}),
		"refund": event.get("refund", {}),
		"resource": str(event.get("resource", "")),
		"gathered": int(event.get("gathered", 0)),
		"amount": int(event.get("amount", 0)),
		"queued_actions_cleared": int(event.get("queued_actions_cleared", 0)),
		"batch_id": str(event.get("batch_id", "")),
		"batch_index": int(event.get("batch_index", 1)),
		"batch_count": int(event.get("batch_count", 1)),
	}


func _local_summary(snapshot: Dictionary, response: Dictionary) -> String:
	var messages: Array = snapshot.get("player_messages", [])
	var player_part = "无主动输入" if messages.is_empty() else "玩家：" + " / ".join(messages).left(80)
	var ai_part = str(response.get("dialogue", "")).left(80)
	var thought = str(response.get("thought", "")).left(80)
	return "%s；AI：%s；思考：%s" % [player_part, ai_part, thought]


func _compact_interaction_payload(snapshot: Dictionary, response: Dictionary) -> Dictionary:
	var player_state: Dictionary = snapshot.get("player", {})
	var ai_state: Dictionary = snapshot.get("ai", {})
	var visible_entities: Array = snapshot.get("visible_entities", [])
	var player_tile = []
	var ai_tile = []
	for entity in visible_entities:
		if typeof(entity) != TYPE_DICTIONARY:
			continue
		if str(entity.get("id", "")) == "player":
			player_tile = entity.get("tile", [])
		elif str(entity.get("id", "")) == "ai":
			ai_tile = entity.get("tile", [])

	var memory_ids = []
	for item in snapshot.get("historical_memories", []):
		if typeof(item) == TYPE_DICTIONARY:
			memory_ids.append(int(item.get("id", -1)))

	return {
		"trigger": str(snapshot.get("trigger", "")),
		"activation": snapshot.get("activation", {}),
		"player_messages": snapshot.get("player_messages", []),
		"player_marked_areas": _compact_player_marked_areas(snapshot.get("player_marked_areas", [])),
		"ai_events": snapshot.get("ai_events", []),
		"game_time": snapshot.get("game_time", {}),
		"player_tile": player_tile,
		"ai_tile": ai_tile,
		"player_attributes": player_state.get("attributes", {}),
		"ai_attributes": ai_state.get("attributes", {}),
		"ai_follow_enabled": bool(ai.follow_enabled),
		"memory_ids": memory_ids,
		"response": {
			"mood": str(response.get("mood", "calm")),
			"dialogue": str(response.get("dialogue", "")).left(240),
			"thought": str(response.get("thought", "")).left(240),
			"set_follow": _follow_signal_from_response(response),
			"has_action": bool(response.get("has_action", false)),
			"action": response.get("action", {}),
			"memory_ops": response.get("memory_ops", {}),
		},
	}


func _compact_player_marked_areas(areas: Array) -> Array:
	var result = []
	for area in areas:
		if typeof(area) != TYPE_DICTIONARY:
			continue
		var map_data: Dictionary = area.get("map", {})
		var notable_tiles: Array = map_data.get("notable_tiles", [])
		result.append({
			"source": str(area.get("source", "")),
			"source_type": str(area.get("source_type", "")),
			"selected_rect": area.get("selected_rect", {}),
			"relative_to": area.get("relative_to", {}),
			"map_size": map_data.get("size", []),
			"counts": map_data.get("counts", {}),
			"notable_tile_count": notable_tiles.size(),
		})
	return result


func _follow_signal_from_response(response: Dictionary) -> int:
	for key in ["set_follow", "follow_enabled", "follow_state"]:
		if not response.has(key):
			continue
		var value = response[key]
		if typeof(value) == TYPE_BOOL:
			return 1 if value else 0
		if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
			var int_value = int(value)
			if int_value == 0 or int_value == 1:
				return int_value
		var text = str(value).to_lower()
		if text == "true" or text == "on" or text == "yes" or text == "1":
			return 1
		if text == "false" or text == "off" or text == "no" or text == "0":
			return 0
	return -1


func _action_from_response(response: Dictionary, snapshot: Dictionary) -> Dictionary:
	var action = response.get("action", {})
	if typeof(action) != TYPE_DICTIONARY:
		return _infer_action_from_context(snapshot, response)

	var type = str(action.get("type", "idle"))
	if type in ["interrupt_action", "interrupt", "cancel_action", "cancel_current_action", "stop_action", "stop", "clear_actions"]:
		return {
			"type": "interrupt_action",
			"reason": str(action.get("reason", type)),
		}

	if type == "move_to_tile" or type == "path_to_tile":
		var tile = action.get("tile", [])
		if typeof(tile) == TYPE_ARRAY and tile.size() >= 2:
			return _with_interrupt_flag({
				"type": type,
				"tile": [int(tile[0]), int(tile[1])],
				"avoid": _string_array(action.get("avoid", [])),
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "search_for_tile" or type == "search_for":
		var target = str(action.get("target", action.get("target_kind", action.get("tile_kind", "")))).strip_edges()
		if not target.is_empty():
			return _with_interrupt_flag({
				"type": "search_for_tile",
				"target": target,
				"scan_radius": int(action.get("scan_radius", action.get("radius", 10))),
				"max_steps": int(action.get("max_steps", action.get("steps", 24))),
				"step_tiles": int(action.get("step_tiles", 8)),
				"avoid": _string_array(action.get("avoid", [])),
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "wander":
		return _with_interrupt_flag({
			"type": "wander",
			"center_tile": action.get("center_tile", []),
			"radius": int(action.get("radius", 16)),
			"steps": int(action.get("steps", 8)),
			"step_tiles": int(action.get("step_tiles", 8)),
			"avoid": _string_array(action.get("avoid", [])),
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		}, action)

	if type == "gather_resource" or type == "gather" or type == "collect_resource" or type == "collect":
		return _with_interrupt_flag({
			"type": "gather_resource",
			"resource": str(action.get("resource", action.get("item", action.get("target_item", "wood")))),
			"target": str(action.get("target", action.get("tile_kind", action.get("target_kind", "")))),
			"amount": int(action.get("amount", 1)),
			"scan_radius": int(action.get("scan_radius", action.get("radius", 10))),
			"max_steps": int(action.get("max_steps", action.get("steps", 24))),
			"step_tiles": int(action.get("step_tiles", 8)),
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		}, action)

	if type == "build_tiles" or type == "build_many" or (type == "build_tile" and (action.has("tiles") or action.has("placements"))):
		var build_actions = _batch_build_actions(action)
		if not build_actions.is_empty():
			return _with_interrupt_flag({"type": "sequence", "actions": build_actions}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "build_tile":
		var build_tile = action.get("tile", [])
		if typeof(build_tile) == TYPE_ARRAY and build_tile.size() >= 2:
			return _with_interrupt_flag({
				"type": "build_tile",
				"tile": [int(build_tile[0]), int(build_tile[1])],
				"tile_kind": GameConfig.normalize_build_kind(str(action.get("tile_kind", action.get("kind", "wood_floor")))),
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "destroy_tiles" or type == "break_tiles" or (type == "destroy_tile" and action.has("tiles")):
		var destroy_actions = _batch_destroy_actions(action)
		if not destroy_actions.is_empty():
			return _with_interrupt_flag({"type": "sequence", "actions": destroy_actions}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "destroy_tile" or type == "break_tile":
		var destroy_tile = action.get("tile", [])
		if typeof(destroy_tile) == TYPE_ARRAY and destroy_tile.size() >= 2:
			return _with_interrupt_flag({
				"type": "destroy_tile",
				"tile": [int(destroy_tile[0]), int(destroy_tile[1])],
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _infer_action_from_context(snapshot, response)

	if type == "follow_player":
		return _with_interrupt_flag({"type": "follow_player"}, action)
	if type == "idle":
		return {"type": "idle"}
	return _infer_action_from_context(snapshot, response)


func _with_interrupt_flag(parsed_action: Dictionary, source_action: Dictionary) -> Dictionary:
	if _action_requests_interrupt(source_action):
		parsed_action["interrupt_current"] = true
	return parsed_action


func _action_requests_interrupt(action: Dictionary) -> bool:
	for key in ["interrupt_current", "interrupt", "replace_current"]:
		if not action.has(key):
			continue
		var value = action[key]
		if typeof(value) == TYPE_BOOL:
			return value
		if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
			return int(value) != 0
		var text = str(value).strip_edges().to_lower()
		if text in ["true", "yes", "1", "on"]:
			return true
	var queue_mode = str(action.get("queue_mode", "")).strip_edges().to_lower()
	return queue_mode in ["replace", "interrupt", "immediate", "now"]


func _infer_action_from_context(snapshot: Dictionary, response: Dictionary) -> Dictionary:
	var text_parts = []
	for message in snapshot.get("player_messages", []):
		text_parts.append(str(message))
	text_parts.append(str(response.get("dialogue", "")))
	text_parts.append(str(response.get("thought", "")))
	var text = " ".join(text_parts)
	var lower = text.to_lower()

	if _text_requests_interrupt(text, lower):
		return {"type": "interrupt_action", "reason": "player_or_response_requested_stop"}

	var wants_gather = lower.contains("gather") or lower.contains("collect") or lower.contains("resource")
	if wants_gather and (lower.contains("stone") or lower.contains("rock")):
		return {"type": "gather_resource", "resource": "stone", "amount": 1, "scan_radius": 12, "max_steps": 32, "step_tiles": 8}
	if wants_gather and (lower.contains("wood") or lower.contains("tree") or lower.contains("log")):
		return {"type": "gather_resource", "resource": "wood", "amount": 1, "scan_radius": 12, "max_steps": 32, "step_tiles": 8}

	var mentions_river = text.contains("河")
	var wants_movement = text.contains("去") or text.contains("看看") or text.contains("探索") or text.contains("前往")
	var wants_search = text.contains("找") or text.contains("寻找") or text.contains("直到找到") or text.contains("搜索")
	var target_kind = _target_kind_from_text(text)
	if wants_search and not target_kind.is_empty():
		return {"type": "search_for_tile", "target": target_kind, "scan_radius": 10, "max_steps": 32, "step_tiles": 8}
	if mentions_river and wants_movement:
		var ai_tile = _tile_from_snapshot_entity(snapshot, "ai")
		var water_tile = _find_nearest_tile_code(snapshot.get("map", {}), "W", ai_tile)
		if not water_tile.is_empty():
			return {"type": "move_to_tile", "tile": water_tile}
	return {}


func _batch_build_actions(action: Dictionary) -> Array:
	var default_kind = GameConfig.normalize_build_kind(str(action.get("tile_kind", action.get("kind", "wood_floor"))))
	var source = action.get("placements", action.get("tiles", []))
	var actions = []
	if not _tile_from_action_item(source).is_empty():
		source = [source]
	if typeof(source) != TYPE_ARRAY:
		return actions
	for item in source:
		var tile = _tile_from_action_item(item)
		if tile.is_empty():
			continue
		var tile_kind = default_kind
		if typeof(item) == TYPE_DICTIONARY:
			tile_kind = GameConfig.normalize_build_kind(str(item.get("tile_kind", item.get("kind", default_kind))))
		if not GameConfig.BUILDABLE_TILE_KINDS.has(tile_kind):
			continue
		actions.append({
			"type": "build_tile",
			"tile": tile,
			"tile_kind": tile_kind,
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		})
	return _tag_batch_actions(actions, "build")


func _batch_destroy_actions(action: Dictionary) -> Array:
	var source = action.get("tiles", [])
	var actions = []
	if not _tile_from_action_item(source).is_empty():
		source = [source]
	if typeof(source) != TYPE_ARRAY:
		return actions
	for item in source:
		var tile = _tile_from_action_item(item)
		if tile.is_empty():
			continue
		actions.append({
			"type": "destroy_tile",
			"tile": tile,
			"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
		})
	return _tag_batch_actions(actions, "destroy")


func _tile_from_action_item(item) -> Array:
	if typeof(item) == TYPE_DICTIONARY:
		return _tile_from_action_item(item.get("tile", item.get("target_tile", [])))
	if typeof(item) == TYPE_ARRAY and item.size() >= 2:
		if not _is_number(item[0]) or not _is_number(item[1]):
			return []
		return [int(item[0]), int(item[1])]
	return []


func _is_number(value) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


func _tag_batch_actions(actions: Array, prefix: String) -> Array:
	var count = actions.size()
	if count <= 0:
		return actions
	var batch_id = "%s_%d_%d" % [prefix, Time.get_ticks_msec(), randi_range(1000, 9999)]
	for index in range(count):
		var item: Dictionary = actions[index]
		item["batch_id"] = batch_id
		item["batch_index"] = index + 1
		item["batch_count"] = count
		actions[index] = item
	return actions


func _string_array(value) -> Array:
	var result = []
	if typeof(value) == TYPE_STRING:
		result.append(str(value))
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			result.append(str(item))
	return result


func _target_kind_from_text(text: String) -> String:
	var lower = text.to_lower()
	if lower.contains("tree") or lower.contains("forest"):
		return "tree"
	if lower.contains("stone_hill") or lower.contains("rock") or lower.contains("hill"):
		return "stone_hill"
	if text.contains("河") or text.contains("水"):
		return "water"
	if text.contains("草地") or text.contains("草"):
		return "grass"
	if text.contains("平地"):
		return "plain"
	if text.contains("树") or text.contains("森林"):
		return "tree"
	if text.contains("石头小山") or text.contains("石山") or text.contains("岩石") or text.contains("小山"):
		return "stone_hill"
	if text.contains("城区") or text.contains("城市"):
		return "city"
	if text.contains("木地板") or text.contains("地板"):
		return "wood_floor"
	if text.contains("石地板"):
		return "stone_floor"
	if text.contains("木墙") or text.contains("墙"):
		return "wood_wall"
	return ""


func _text_requests_interrupt(text: String, lower: String) -> bool:
	if lower.contains("stop") or lower.contains("cancel") or lower.contains("interrupt") or lower.contains("halt") or lower.contains("wait"):
		return true
	return text.contains("停") or text.contains("别去了") or text.contains("不要去了") or text.contains("取消") or text.contains("中断") or text.contains("等一下") or text.contains("先别")


func _small_int_array(value, max_count: int) -> Array:
	var result = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value.slice(0, min(max_count, value.size())):
		result.append(int(item))
	return result


func _small_float_array(value, max_count: int) -> Array:
	var result = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value.slice(0, min(max_count, value.size())):
		result.append(float(item))
	return result


func _tile_from_snapshot_entity(snapshot: Dictionary, entity_id: String) -> Array:
	for entity in snapshot.get("visible_entities", []):
		if typeof(entity) == TYPE_DICTIONARY and str(entity.get("id", "")) == entity_id:
			var tile = entity.get("tile", [])
			if typeof(tile) == TYPE_ARRAY and tile.size() >= 2:
				return [int(tile[0]), int(tile[1])]
	return [0, 0]


func _find_nearest_tile_code(map_data: Dictionary, code: String, from_tile: Array) -> Array:
	var origin = map_data.get("origin", [0, 0])
	var rows = map_data.get("rows", [])
	if typeof(origin) != TYPE_ARRAY or origin.size() < 2 or typeof(rows) != TYPE_ARRAY:
		return []

	var best_tile = []
	var best_distance = INF
	var from_x = int(from_tile[0])
	var from_y = int(from_tile[1])
	for row_index in range(rows.size()):
		var row = str(rows[row_index])
		for column_index in range(row.length()):
			if row[column_index] != code:
				continue
			var tile_x = int(origin[0]) + column_index
			var tile_y = int(origin[1]) + row_index
			var distance = Vector2(tile_x - from_x, tile_y - from_y).length_squared()
			if distance < best_distance:
				best_distance = distance
				best_tile = [tile_x, tile_y]
	return best_tile


func _parse_json_content(content: String):
	var parsed = JSON.parse_string(content)
	if parsed != null:
		return parsed

	var start = content.find("{")
	var end = content.rfind("}")
	if start >= 0 and end > start:
		return JSON.parse_string(content.substr(start, end - start + 1))
	return null


func _on_llm_completed(request_id: int, payload: Dictionary) -> void:
	if _pending_brain.has(request_id):
		var snapshot: Dictionary = _pending_brain[request_id]
		_pending_brain.erase(request_id)
		var parsed = _parse_json_content(str(payload.get("content", "")))
		if typeof(parsed) == TYPE_DICTIONARY:
			_apply_ai_response(parsed, snapshot)
		else:
			debug_event.emit("Brain JSON parse failed; using fallback.")
			_apply_ai_response(_offline_brain(snapshot), snapshot)
		return

	if _pending_compression.has(request_id):
		var pending: Dictionary = _pending_compression[request_id]
		_pending_compression.erase(request_id)
		var parsed = _parse_json_content(str(payload.get("content", "")))
		var summary = str(pending.get("fallback", ""))
		if typeof(parsed) == TYPE_DICTIONARY:
			var parsed_summary = str(parsed.get("summary", "")).strip_edges()
			if not parsed_summary.is_empty():
				summary = parsed_summary
		memory.add_recent(summary, "interaction", float(pending.get("game_minutes", clock.game_minutes)), pending.get("payload", {}))


func _on_llm_failed(request_id: int, error_message: String) -> void:
	if _pending_brain.has(request_id):
		var snapshot: Dictionary = _pending_brain[request_id]
		_pending_brain.erase(request_id)
		debug_event.emit(error_message)
		_apply_ai_response(_offline_brain(snapshot), snapshot)
		return

	if _pending_compression.has(request_id):
		var pending: Dictionary = _pending_compression[request_id]
		_pending_compression.erase(request_id)
		memory.add_recent(str(pending.get("fallback", "")), "interaction", float(pending.get("game_minutes", clock.game_minutes)), pending.get("payload", {}))


func _perception_interval() -> float:
	return float(game_api.get_runtime_parameter("ai.perception_interval_game_minutes", GameConfig.PERCEPTION_INTERVAL_GAME_MINUTES))


func _perception_map_tile_size() -> int:
	return max(1, int(game_api.get_runtime_parameter("ai.perception_map_tile_size", GameConfig.PERCEPTION_MAP_TILE_SIZE)))


func _perception_ray_tile_length() -> int:
	return max(1, int(game_api.get_runtime_parameter("ai.perception_ray_tile_length", GameConfig.PERCEPTION_RAY_TILE_LENGTH)))


func _memory_recall_count() -> int:
	return int(game_api.get_runtime_parameter("ai.memory_recall_count", GameConfig.MEMORY_RECALL_COUNT))


func _forget_interval() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_interval_game_minutes", GameConfig.FORGET_INTERVAL_GAME_MINUTES))


func _forget_percent() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_percent", GameConfig.FORGET_PERCENT))
