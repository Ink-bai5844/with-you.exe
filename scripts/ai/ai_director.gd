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
	queued_ai_events.clear()
	_pending_brain.clear()
	_pending_compression.clear()
	thinking_changed.emit(false)


func on_player_message(text: String) -> void:
	var trimmed = text.strip_edges()
	if trimmed.is_empty():
		return
	queued_player_messages.append(trimmed)
	_request_perception("player_message")


func _on_ai_action_event(event: Dictionary) -> void:
	queued_ai_events.append(_sanitize_ai_event(event))
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
	var ai_events = queued_ai_events.duplicate(true)
	queued_player_messages.clear()
	queued_ai_events.clear()
	var snapshot = _build_perception(trigger, player_messages, ai_events)

	if llm.is_configured():
		var request_id = llm.chat(_brain_messages(snapshot), {"json_response": true, "temperature": 0.35})
		_pending_brain[request_id] = snapshot
	else:
		_apply_ai_response(_offline_brain(snapshot), snapshot)


func _build_perception(trigger: String, player_messages: Array, ai_events: Array) -> Dictionary:
	var player_tile = world.world_to_tile(player.global_position)
	var ai_tile = world.world_to_tile(ai.global_position)
	var memories = memory.recall(_memory_recall_count(), clock.game_minutes)
	var activation = _build_activation(trigger, player_messages, ai_events)
	return {
		"trigger": trigger,
		"activation": activation,
		"player_messages": player_messages,
		"ai_events": ai_events,
		"map": world.encode_area(player_tile, 12),
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


func _build_activation(trigger: String, player_messages: Array, ai_events: Array) -> Dictionary:
	var has_player_messages = not player_messages.is_empty()
	var is_player_initiated = trigger == "player_message" or trigger == "queued_player_message" or has_player_messages
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
	elif is_ai_action_event:
		reply_policy = "Triggered by your own action result. Reply only if the event is useful for the player to know, such as finding a target, failing a search, or completing an assigned task."

	return {
		"trigger": trigger,
		"source": source,
		"is_player_initiated": is_player_initiated,
		"is_automatic_perception": is_automatic_perception,
		"is_ai_action_event": is_ai_action_event,
		"player_message_count": player_messages.size(),
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
		if event_type in ["search_target_found", "search_failed", "action_completed"]:
			return true
		if status in ["found", "failed", "completed"]:
			return true
	return false


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
	var protocol = "Return only JSON. Schema: {\"talk_to_player\":bool,\"dialogue\":string,\"has_action\":bool,\"action\":object,\"set_follow\":-1|0|1,\"mood\":\"%s\",\"thought\":string,\"memory_ops\":{\"add\":[{\"summary\":string,\"priority\":int}],\"update_priority\":[{\"id\":int,\"priority\":int}],\"delete\":[int]}}. set_follow controls persistent follow state: -1 unchanged, 0 stop following the player, 1 follow the player. The default follow state is off. Supported actions: {\"type\":\"move_to_tile\",\"tile\":[x,y]} moves directly; {\"type\":\"path_to_tile\",\"tile\":[x,y],\"avoid\":[\"water\"]} pathfinds through nearby tiles while avoiding listed terrain; {\"type\":\"search_for_tile\",\"target\":\"water|grass|plain|city|city_border\",\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8,\"avoid\":[]} keeps walking and scanning until that terrain is found or steps run out; {\"type\":\"wander\",\"radius\":16,\"steps\":8,\"step_tiles\":8,\"avoid\":[\"water\"]} explores around the current area; {\"type\":\"follow_player\"} moves near the player once; {\"type\":\"idle\"} stops. The perception may include ai_events such as search_target_found, search_failed, or action_completed. Treat these events as your own new observation: acknowledge important discoveries, remember useful findings, and choose the next action if needed. If the player asks you to follow or stop following, return set_follow accordingly. If you say you will go somewhere or search for something, set has_action=true and return an executable action. The map rows use the origin and legend; W means river water. Do not only promise movement in dialogue. You may update/delete recalled memories by id." % mood_values
	var activation_protocol = "The snapshot includes activation. activation.source is one of player_interaction, auto_perception, or ai_action_event. If activation.is_player_initiated is true, the player actively spoke to you; normally answer the player. If activation.is_automatic_perception is true, this is a background sensing tick; normally keep talk_to_player=false and dialogue=\"\" unless the situation is important enough to interrupt the player. If activation.is_ai_action_event is true, respond only when your action result matters to the player. Use activation.reply_policy and activation.should_consider_reply when deciding whether to return dialogue; you may still return actions, mood, thought, and memory_ops without speaking."
	return "\n".join(profile_lines) + "\n\n" + protocol + "\n" + activation_protocol


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
		"background": "You and the human player have arrived in a simple sandbox world with a central city area, grass, plains, and rivers.",
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
	if not queued_player_messages.is_empty():
		_request_perception("queued_player_message")
	elif not queued_ai_events.is_empty():
		_request_perception("queued_ai_action_event")


func _offline_brain(snapshot: Dictionary) -> Dictionary:
	var player_messages: Array = snapshot.get("player_messages", [])
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
		"found_tile": _small_int_array(event.get("found_tile", []), 2),
		"target_tile": _small_int_array(event.get("target_tile", []), 2),
		"ai_tile": _small_int_array(event.get("ai_tile", []), 2),
		"ai_position": _small_float_array(event.get("ai_position", []), 2),
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
	if type == "move_to_tile" or type == "path_to_tile":
		var tile = action.get("tile", [])
		if typeof(tile) == TYPE_ARRAY and tile.size() >= 2:
			return {
				"type": type,
				"tile": [int(tile[0]), int(tile[1])],
				"avoid": _string_array(action.get("avoid", [])),
				"max_nodes": int(action.get("max_nodes", 5000)),
			}
		return _infer_action_from_context(snapshot, response)

	if type == "search_for_tile" or type == "search_for":
		var target = str(action.get("target", action.get("target_kind", action.get("tile_kind", "")))).strip_edges()
		if not target.is_empty():
			return {
				"type": "search_for_tile",
				"target": target,
				"scan_radius": int(action.get("scan_radius", action.get("radius", 10))),
				"max_steps": int(action.get("max_steps", action.get("steps", 24))),
				"step_tiles": int(action.get("step_tiles", 8)),
				"avoid": _string_array(action.get("avoid", [])),
				"max_nodes": int(action.get("max_nodes", 5000)),
			}
		return _infer_action_from_context(snapshot, response)

	if type == "wander":
		return {
			"type": "wander",
			"center_tile": action.get("center_tile", []),
			"radius": int(action.get("radius", 16)),
			"steps": int(action.get("steps", 8)),
			"step_tiles": int(action.get("step_tiles", 8)),
			"avoid": _string_array(action.get("avoid", [])),
			"max_nodes": int(action.get("max_nodes", 5000)),
		}

	if type == "follow_player":
		return {"type": "follow_player"}
	if type == "idle":
		return {"type": "idle"}
	return _infer_action_from_context(snapshot, response)


func _infer_action_from_context(snapshot: Dictionary, response: Dictionary) -> Dictionary:
	var text_parts = []
	for message in snapshot.get("player_messages", []):
		text_parts.append(str(message))
	text_parts.append(str(response.get("dialogue", "")))
	text_parts.append(str(response.get("thought", "")))
	var text = " ".join(text_parts)

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


func _string_array(value) -> Array:
	var result = []
	if typeof(value) == TYPE_STRING:
		result.append(str(value))
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			result.append(str(item))
	return result


func _target_kind_from_text(text: String) -> String:
	if text.contains("河") or text.contains("水"):
		return "water"
	if text.contains("草地") or text.contains("草"):
		return "grass"
	if text.contains("平地"):
		return "plain"
	if text.contains("城区") or text.contains("城市"):
		return "city"
	return ""


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


func _memory_recall_count() -> int:
	return int(game_api.get_runtime_parameter("ai.memory_recall_count", GameConfig.MEMORY_RECALL_COUNT))


func _forget_interval() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_interval_game_minutes", GameConfig.FORGET_INTERVAL_GAME_MINUTES))


func _forget_percent() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_percent", GameConfig.FORGET_PERCENT))
