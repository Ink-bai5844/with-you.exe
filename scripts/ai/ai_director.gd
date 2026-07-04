class_name AIDirector
extends Node

signal ai_spoke(text, mood)
signal thinking_changed(active)
signal debug_event(text)
signal ai_tasks_changed(tasks)

const GameConfig = preload("res://scripts/config/game_config.gd")
const AI_PROMPT_PATH = "res://config/ai_prompt.json"
const TASK_STATUS_PENDING = "pending"
const TASK_STATUS_RUNNING = "running"
const TASK_STATUS_COMPLETED = "completed"
const TASK_STATUS_BLOCKED = "blocked"
const TASK_STATUS_CANCELLED = "cancelled"

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
var ai_tasks: Array = []
var active_task_id = ""
var next_task_id = 1

var _pending_brain = {}
var _pending_task_detail = {}
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


func tasks_snapshot() -> Array:
	return ai_tasks.duplicate(true)


func begin() -> void:
	started = true
	next_perception_minutes = clock.game_minutes + _perception_interval()
	next_forget_minutes = clock.game_minutes + _forget_interval()
	if ai_tasks.is_empty():
		active_task_id = ""
		next_task_id = max(1, next_task_id)
		_emit_tasks_changed()
	debug_event.emit("AI director started.")


func stop() -> void:
	started = false
	busy = false
	queued_player_messages.clear()
	queued_player_marked_areas.clear()
	queued_ai_events.clear()
	_pending_brain.clear()
	_pending_task_detail.clear()
	_pending_compression.clear()
	ai_tasks.clear()
	active_task_id = ""
	next_task_id = 1
	_emit_tasks_changed()
	thinking_changed.emit(false)


func get_save_data() -> Dictionary:
	return {
		"started": started,
		"next_perception_minutes": next_perception_minutes,
		"next_forget_minutes": next_forget_minutes,
		"ai_prompt": ai_prompt.duplicate(true),
		"ai_tasks": ai_tasks.duplicate(true),
		"active_task_id": active_task_id,
		"next_task_id": next_task_id,
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
	_pending_task_detail.clear()
	_pending_compression.clear()
	ai_tasks = _tasks_from_value(data.get("ai_tasks", []))
	active_task_id = str(data.get("active_task_id", ""))
	next_task_id = int(max(1, int(data.get("next_task_id", _infer_next_task_id()))))
	if _task_index_by_id(active_task_id) < 0:
		active_task_id = ""
	_emit_tasks_changed()
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
	_update_task_from_ai_event(sanitized)
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
		var request_id = llm.chat(_brain_messages(snapshot), {"temperature": 0.35})
		_pending_brain[request_id] = snapshot
	else:
		_apply_task_plan_response(_offline_task_plan(snapshot), snapshot)


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
		"ai_tasks": tasks_snapshot(),
		"active_task_id": active_task_id,
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


func _emit_tasks_changed() -> void:
	ai_tasks_changed.emit(tasks_snapshot())


func _tasks_from_value(value) -> Array:
	var result = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var task = item.duplicate(true)
		var id_text = str(task.get("id", "")).strip_edges()
		if id_text.is_empty():
			id_text = _make_task_id()
		task["id"] = id_text
		task["title"] = str(task.get("title", task.get("objective", "未命名任务"))).strip_edges().left(80)
		task["objective"] = str(task.get("objective", task["title"])).strip_edges().left(600)
		task["kind"] = str(task.get("kind", "general")).strip_edges().to_lower()
		task["status"] = _normalized_task_status(str(task.get("status", TASK_STATUS_PENDING)))
		task["priority"] = int(clamp(int(task.get("priority", 5)), 1, 9))
		task["created_game_minutes"] = int(task.get("created_game_minutes", clock.game_minutes if clock != null else 0))
		task["updated_game_minutes"] = int(task.get("updated_game_minutes", task["created_game_minutes"]))
		task["notes"] = str(task.get("notes", "")).left(800)
		task["last_result"] = str(task.get("last_result", "")).left(800)
		task["detail_attempts"] = int(max(0, int(task.get("detail_attempts", 0))))
		result.append(task)
	return result


func _infer_next_task_id() -> int:
	var highest = 0
	for task in ai_tasks:
		if typeof(task) != TYPE_DICTIONARY:
			continue
		var id_text = str(task.get("id", ""))
		var parts = id_text.split("_")
		var suffix = str(parts[parts.size() - 1]) if parts.size() > 0 else id_text
		if suffix.is_valid_int():
			highest = max(highest, int(suffix))
	return highest + 1


func _make_task_id() -> String:
	var id_text = "task_%03d" % next_task_id
	next_task_id += 1
	return id_text


func _normalized_task_status(value: String) -> String:
	var lower = value.strip_edges().to_lower()
	match lower:
		"todo", "queued", "new", "open", "等待", "待办":
			return TASK_STATUS_PENDING
		"active", "doing", "in_progress", "执行中", "进行中":
			return TASK_STATUS_RUNNING
		"done", "finished", "success", "完成", "已完成":
			return TASK_STATUS_COMPLETED
		"failed", "blocked", "stuck", "失败", "卡住":
			return TASK_STATUS_BLOCKED
		"cancelled", "canceled", "deleted", "stop", "stopped", "取消", "停止":
			return TASK_STATUS_CANCELLED
		_:
			if lower in [TASK_STATUS_PENDING, TASK_STATUS_RUNNING, TASK_STATUS_COMPLETED, TASK_STATUS_BLOCKED, TASK_STATUS_CANCELLED]:
				return lower
	return TASK_STATUS_PENDING


func _task_index_by_id(task_id: String) -> int:
	var id_text = str(task_id)
	for index in range(ai_tasks.size()):
		var task = ai_tasks[index]
		if typeof(task) == TYPE_DICTIONARY and str(task.get("id", "")) == id_text:
			return index
	return -1


func _add_task(raw_task: Dictionary, source: String) -> Dictionary:
	var title = str(raw_task.get("title", raw_task.get("name", raw_task.get("objective", "新任务")))).strip_edges()
	var objective = str(raw_task.get("objective", raw_task.get("description", title))).strip_edges()
	if title.is_empty() and not objective.is_empty():
		title = objective.left(28)
	if objective.is_empty():
		objective = title
	if title.is_empty() or objective.is_empty():
		return {}

	var task = {
		"id": _make_task_id(),
		"title": title.left(80),
		"objective": objective.left(600),
		"kind": str(raw_task.get("kind", raw_task.get("type", "general"))).strip_edges().to_lower(),
		"priority": int(clamp(int(raw_task.get("priority", 5)), 1, 9)),
		"status": _normalized_task_status(str(raw_task.get("status", TASK_STATUS_PENDING))),
		"source": source,
		"created_game_minutes": int(clock.game_minutes),
		"updated_game_minutes": int(clock.game_minutes),
		"notes": str(raw_task.get("notes", raw_task.get("reason", ""))).left(800),
		"last_result": "",
		"detail_attempts": 0,
	}
	ai_tasks.append(task)
	return task


func _update_task(raw_task: Dictionary) -> bool:
	var task_id = str(raw_task.get("id", raw_task.get("task_id", ""))).strip_edges()
	var index = _task_index_by_id(task_id)
	if index < 0:
		return false
	var task: Dictionary = ai_tasks[index]
	for key in ["title", "objective", "kind", "notes", "last_result"]:
		if raw_task.has(key):
			task[key] = str(raw_task[key]).strip_edges().left(800 if key == "notes" or key == "last_result" else 600)
	if raw_task.has("priority"):
		task["priority"] = int(clamp(int(raw_task["priority"]), 1, 9))
	if raw_task.has("status"):
		task["status"] = _normalized_task_status(str(raw_task["status"]))
	task["updated_game_minutes"] = int(clock.game_minutes)
	ai_tasks[index] = task
	if task["status"] in [TASK_STATUS_COMPLETED, TASK_STATUS_BLOCKED, TASK_STATUS_CANCELLED] and active_task_id == task_id:
		active_task_id = ""
	return true


func _delete_task(task_id) -> bool:
	var index = _task_index_by_id(str(task_id))
	if index < 0:
		return false
	if str(ai_tasks[index].get("id", "")) == active_task_id:
		active_task_id = ""
		if ai != null:
			ai.enqueue_action({"type": "interrupt_action", "reason": "task_deleted"})
	ai_tasks.remove_at(index)
	return true


func _stop_current_task(reason: String) -> void:
	if active_task_id.is_empty():
		if ai != null:
			ai.enqueue_action({"type": "interrupt_action", "reason": reason})
		return
	var index = _task_index_by_id(active_task_id)
	if index >= 0:
		var task: Dictionary = ai_tasks[index]
		task["status"] = TASK_STATUS_CANCELLED
		task["last_result"] = reason
		task["updated_game_minutes"] = int(clock.game_minutes)
		ai_tasks[index] = task
	active_task_id = ""
	if ai != null:
		ai.enqueue_action({"type": "interrupt_action", "reason": reason})


func _clear_all_tasks(reason: String) -> void:
	ai_tasks.clear()
	active_task_id = ""
	if ai != null:
		ai.enqueue_action({"type": "interrupt_action", "reason": reason})


func _task_is_runnable(task: Dictionary) -> bool:
	return str(task.get("status", TASK_STATUS_PENDING)) in [TASK_STATUS_PENDING, TASK_STATUS_RUNNING]


func _active_or_next_task() -> Dictionary:
	var active_index = _task_index_by_id(active_task_id)
	if active_index >= 0:
		var active_task: Dictionary = ai_tasks[active_index]
		if _task_is_runnable(active_task):
			return active_task.duplicate(true)

	var best_index = -1
	var best_score = -INF
	for index in range(ai_tasks.size()):
		var task = ai_tasks[index]
		if typeof(task) != TYPE_DICTIONARY or not _task_is_runnable(task):
			continue
		var score = float(int(task.get("priority", 5))) * 100000.0 - float(int(task.get("created_game_minutes", 0)))
		if best_index < 0 or score > best_score:
			best_index = index
			best_score = score
	if best_index < 0:
		active_task_id = ""
		return {}
	active_task_id = str(ai_tasks[best_index].get("id", ""))
	return ai_tasks[best_index].duplicate(true)


func _set_task_status(task_id: String, status: String, last_result = "") -> void:
	var index = _task_index_by_id(task_id)
	if index < 0:
		return
	var task: Dictionary = ai_tasks[index]
	task["status"] = _normalized_task_status(status)
	if not str(last_result).is_empty():
		task["last_result"] = str(last_result).left(800)
	task["updated_game_minutes"] = int(clock.game_minutes)
	ai_tasks[index] = task
	if task["status"] in [TASK_STATUS_COMPLETED, TASK_STATUS_BLOCKED, TASK_STATUS_CANCELLED] and active_task_id == task_id:
		active_task_id = ""
	_emit_tasks_changed()


func _ai_has_pending_actions() -> bool:
	if ai == null:
		return false
	var current = ai.get("current_action")
	var queue = ai.get("action_queue")
	return (typeof(current) == TYPE_DICTIONARY and not current.is_empty()) or (typeof(queue) == TYPE_ARRAY and not queue.is_empty())


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
	if not _action_result_trigger_perception_enabled() and _is_action_result_perception_event(event):
		return false
	if batch_count > 1 and event_type in ["build_completed", "destroy_completed"] and status == "completed":
		return batch_index >= batch_count
	return true


func _is_action_result_perception_event(event: Dictionary) -> bool:
	var event_type = str(event.get("event_type", "")).strip_edges().to_lower()
	var action_type = str(event.get("action_type", "")).strip_edges().to_lower()
	var status = str(event.get("status", "")).strip_edges().to_lower()
	if event_type == "search_target_found":
		return true
	if event_type != "action_completed":
		return false
	if action_type in ["move_to_tile", "path_to_tile", "search_for_tile", "follow_player"]:
		return true
	return status in ["arrived", "arrived_at_found_tile", "reached_target"]


func _brain_messages(snapshot: Dictionary) -> Array:
	return [
		{
			"role": "system",
			"content": _build_task_planning_prompt()
		},
		{
			"role": "user",
			"content": JSON.stringify(snapshot)
		}
	]


func _task_detail_messages(snapshot: Dictionary, task: Dictionary) -> Array:
	var detail_payload = snapshot.duplicate(true)
	detail_payload["task_to_detail"] = task.duplicate(true)
	return [
		{
			"role": "system",
			"content": _build_task_detail_prompt()
		},
		{
			"role": "user",
			"content": JSON.stringify(detail_payload)
		}
	]


func _profile_prompt_text() -> String:
	var profile_lines = [
		"Character name: %s" % str(ai_prompt.get("character_name", "悠")),
		"Role: %s" % str(ai_prompt.get("role", "AI player and companion in a 2D pixel sandbox life game.")),
		"Background: %s" % str(ai_prompt.get("background", "")),
		"Personality: %s" % _prompt_list(ai_prompt.get("personality", [])),
		"Speaking style: %s" % str(ai_prompt.get("speaking_style", "")),
		"Relationship to player: %s" % str(ai_prompt.get("relationship_to_player", "")),
		"Extra rules: %s" % str(ai_prompt.get("extra_system_prompt", "")),
	]
	return "\n".join(profile_lines)


func _build_task_planning_prompt() -> String:
	var mood_values = "|".join(GameConfig.MOODS)
	var protocol = "Return only JSON. This is the TASK PLANNING layer, not the action-detail layer. Do not return complete movement/build/destroy parameters and do not return an action object. Schema: {\"talk_to_player\":bool,\"dialogue\":string,\"set_follow\":-1|0|1,\"mood\":\"%s\",\"thought\":string,\"task_ops\":{\"add\":[{\"title\":string,\"objective\":string,\"kind\":\"move|search|gather|build|destroy|talk|wait|general\",\"priority\":1-9,\"notes\":string}],\"update\":[{\"id\":string,\"title\":string,\"objective\":string,\"status\":\"pending|running|completed|blocked|cancelled\",\"priority\":1-9,\"notes\":string,\"last_result\":string}],\"delete\":[string],\"stop_current\":bool,\"clear_all\":bool},\"memory_ops\":{\"add\":[{\"summary\":string,\"priority\":int}],\"update_priority\":[{\"id\":int,\"priority\":int}],\"delete\":[int]}}." % mood_values
	var task_rules = "You maintain ai_tasks. Convert player instructions, automatic perception, and your own action results into a concise task list. Add tasks for goals like exploring, gathering resources, building, destroying, following up on discoveries, or answering a player-directed objective. Update or delete stale tasks when ai_events show they are completed, impossible, cancelled, or superseded. If the player asks you to stop/cancel/interrupt your current work, set task_ops.stop_current=true and delete or cancel the relevant task. If the player says to forget all current work, set task_ops.clear_all=true. Keep task objective high-level enough for a second model call to refine with fresh map perception. Never include exact tile lists or full build placements here unless the task itself is just a rough human objective."
	var activation_protocol = "The snapshot includes activation. activation.source is player_interaction, auto_perception, or ai_action_event. If activation.is_player_initiated is true, normally answer the player and update tasks from the message. If activation.is_automatic_perception is true, usually keep talk_to_player=false and only adjust tasks if something important changed. If activation.is_ai_action_event is true, use ai_events to mark task progress/completion/failure and decide whether the player should hear about it."
	var perception_protocol = "The snapshot also includes the same map, map_rays, visible_entities, player/AI state, inventory, memories, runtime_api, and player_marked_areas used by action-detail calls. Use that information only to decide or revise tasks; detailed action parameters will be generated later from each task with another perception snapshot."
	return _profile_prompt_text() + "\n\n" + protocol + "\n" + task_rules + "\n" + activation_protocol + "\n" + perception_protocol


func _build_task_detail_prompt() -> String:
	var task_protocol = "This is the TASK DETAIL tool-call layer. You receive task_to_detail plus the same map and state perception as automatic real-time sensing. Refine only this one task into executable action parameters for the game automaton. This call is silent: the AI character must not speak to the player here."
	var response_protocol = "Return only JSON. Do not return talk_to_player, dialogue, mood, thought, or any player-facing text. Schema: {\"has_action\":bool,\"action\":object,\"set_follow\":-1|0|1,\"task_status\":\"pending|running|completed|blocked|cancelled\",\"task_update\":{\"status\":string,\"notes\":string,\"last_result\":string},\"memory_ops\":{\"add\":[{\"summary\":string,\"priority\":int}],\"update_priority\":[{\"id\":int,\"priority\":int}],\"delete\":[int]}}. If the task needs game execution now, set has_action=true and return one supported action. If no action is needed, set has_action=false and explain only via task_status/task_update."
	var action_protocol = "Supported action objects: {\"type\":\"move_to_tile\",\"tile\":[x,y]} moves directly; {\"type\":\"path_to_tile\",\"tile\":[x,y],\"avoid\":[\"water\",\"wood_wall\",\"tree\",\"stone_hill\"]} pathfinds through nearby tiles while avoiding listed terrain; {\"type\":\"search_for_tile\",\"target\":\"water|grass|plain|tree|stone_hill|city|city_border|wood_floor|stone_floor|wood_wall\",\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8,\"avoid\":[]} keeps walking and scanning until that terrain is found or steps run out; {\"type\":\"wander\",\"radius\":16,\"steps\":8,\"step_tiles\":8,\"avoid\":[\"water\"]}; {\"type\":\"gather_resource\",\"resource\":\"wood|stone\",\"amount\":1,\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8}; {\"type\":\"build_tile\",\"tile\":[x,y],\"tile_kind\":\"wood_floor|stone_floor|wood_wall\"}; {\"type\":\"build_tiles\",\"tile_kind\":\"wood_floor|stone_floor|wood_wall\",\"tiles\":[[x,y],[x,y]]}; {\"type\":\"build_tiles\",\"placements\":[{\"tile\":[x,y],\"tile_kind\":\"wood_floor\"}]}; {\"type\":\"destroy_tile\",\"tile\":[x,y]}; {\"type\":\"destroy_tiles\",\"tiles\":[[x,y],[x,y]]}; {\"type\":\"follow_player\"}; {\"type\":\"idle\"}; {\"type\":\"interrupt_action\",\"reason\":\"player_request\"}. Use \"interrupt_current\":true on a new action when it should replace the old path."
	var world_protocol = "Player and AI state include inventory. Build costs are wood_floor=1 wood, stone_floor=1 stone, wood_wall=2 wood. Water is not walkable in normal mode; wood_floor can be built directly on water to make a walkable bridge. Destroying tree terrain yields wood; destroying stone_hill yields stone. The automaton executes batch build/destroy tasks one by one, so you may return many planned tiles at once. The map rows are centered on the AI tile and limited by the configured perception map size. map_rays contains eight compass rays from the AI tile and reports only the earliest position and attributes for each new tile kind encountered along that direction. W means river water, T tree, H stone hill, F wood floor, S stone floor, X wood wall."
	return task_protocol + "\n" + response_protocol + "\n" + action_protocol + "\n" + world_protocol


func _build_system_prompt() -> String:
	var mood_values = "|".join(GameConfig.MOODS)
	var protocol = "Return only JSON. Schema: {\"talk_to_player\":bool,\"dialogue\":string,\"has_action\":bool,\"action\":object,\"set_follow\":-1|0|1,\"mood\":\"%s\",\"thought\":string,\"memory_ops\":{\"add\":[{\"summary\":string,\"priority\":int}],\"update_priority\":[{\"id\":int,\"priority\":int}],\"delete\":[int]}}. set_follow controls persistent follow state: -1 unchanged, 0 stop following the player, 1 follow the player. The default follow state is off. Supported actions: {\"type\":\"move_to_tile\",\"tile\":[x,y]} moves directly; {\"type\":\"path_to_tile\",\"tile\":[x,y],\"avoid\":[\"water\",\"wood_wall\",\"tree\",\"stone_hill\"]} pathfinds through nearby tiles while avoiding listed terrain; {\"type\":\"search_for_tile\",\"target\":\"water|grass|plain|tree|stone_hill|city|city_border|wood_floor|stone_floor|wood_wall\",\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8,\"avoid\":[]} keeps walking and scanning until that terrain is found or steps run out; {\"type\":\"wander\",\"radius\":16,\"steps\":8,\"step_tiles\":8,\"avoid\":[\"water\"]} explores around the current area; {\"type\":\"gather_resource\",\"resource\":\"wood|stone\",\"amount\":1,\"scan_radius\":10,\"max_steps\":24,\"step_tiles\":8} searches for a matching resource source, walks adjacent, destroys it, and adds drops to your inventory; {\"type\":\"build_tile\",\"tile\":[x,y],\"tile_kind\":\"wood_floor|stone_floor|wood_wall\"} builds one tile using your inventory; {\"type\":\"build_tiles\",\"tile_kind\":\"wood_floor|stone_floor|wood_wall\",\"tiles\":[[x,y],[x,y]]} builds many same-kind tiles; {\"type\":\"build_tiles\",\"placements\":[{\"tile\":[x,y],\"tile_kind\":\"wood_floor\"},{\"tile\":[x,y],\"tile_kind\":\"wood_wall\"}]} builds many mixed-kind tiles; {\"type\":\"destroy_tile\",\"tile\":[x,y]} removes one built tile or destroys a tree/stone_hill terrain tile and recovers materials; {\"type\":\"destroy_tiles\",\"tiles\":[[x,y],[x,y]]} removes many built tiles, trees, or stone hills; {\"type\":\"follow_player\"} moves near the player once; {\"type\":\"idle\"} stops. Player and AI state include inventory; build costs are wood_floor=1 wood, stone_floor=1 stone, wood_wall=2 wood. Water is not walkable in normal mode; wood_floor can be built directly on water to make a walkable bridge. Destroying tree terrain yields wood; destroying stone_hill yields stone. Use gather_resource when you want to collect resources proactively instead of only searching. The automaton will execute batch build/destroy tasks one by one; you can return many planned tiles at once. The perception may include ai_events such as search_target_found, search_failed, action_completed, build_completed, build_failed, destroy_completed, destroy_failed, gather_progress, gather_completed, gather_failed, or movement_unstuck_teleport. Batch events include batch_id, batch_index, and batch_count. Treat these events as your own new observation: acknowledge important discoveries, remember useful findings, and choose the next action if needed. If the player asks you to follow or stop following, return set_follow accordingly. If you say you will go somewhere, search, build, gather, or destroy something, set has_action=true and return an executable action. The map rows are centered on your current tile and limited by the configured perception map size; use the origin and legend. map_rays contains eight compass rays from your tile, up to the configured ray length, and may see beyond the screen; each ray reports only the earliest position and attributes for each new tile kind encountered along that direction. W means river water, T tree, H stone hill, F wood floor, S stone floor, X wood wall. Do not only promise movement, gathering, or building in dialogue. You may update/delete recalled memories by id." % mood_values
	var interrupt_protocol = "Pathfinding and long actions are interruptible. If the player asks you to stop, cancel, wait, interrupt the current route, or abandon a task, return has_action=true and action {\"type\":\"interrupt_action\",\"reason\":\"player_request\"}. If the player gives a new urgent destination/task that should replace the old one, include \"interrupt_current\":true on the new action instead of queueing behind the old path."
	var activation_protocol = "The snapshot includes activation. activation.source is one of player_interaction, auto_perception, or ai_action_event. If activation.is_player_initiated is true, the player actively spoke to you; normally answer the player. If activation.is_automatic_perception is true, this is a background sensing tick; normally keep talk_to_player=false and dialogue=\"\" unless the situation is important enough to interrupt the player. If activation.is_ai_action_event is true, respond only when your action result matters to the player. Use activation.reply_policy and activation.should_consider_reply when deciding whether to return dialogue; you may still return actions, mood, thought, and memory_ops without speaking."
	var player_mark_protocol = "The snapshot may include player_marked_areas. These are rectangular map regions that the human player actively selected with the mouse before sending the current message. Treat them as explicit player-directed context or pointing gestures, not automatic perception. Each marked area contains selected_rect, rows, legend, counts, and notable_tiles."
	return _profile_prompt_text() + "\n\n" + protocol + "\n" + interrupt_protocol + "\n" + activation_protocol + "\n" + player_mark_protocol


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


func _apply_task_plan_response(response: Dictionary, snapshot: Dictionary) -> void:
	var mood = str(response.get("mood", "calm"))
	ai.set_mood(mood)

	var follow_signal = _follow_signal_from_response(response)
	if follow_signal != -1:
		ai.set_follow_enabled(follow_signal == 1)

	var memory_ops = response.get("memory_ops", {})
	if typeof(memory_ops) == TYPE_DICTIONARY:
		memory.apply_ai_memory_ops(memory_ops, clock.game_minutes)

	_apply_task_ops(response, snapshot)

	var dialogue = str(response.get("dialogue", "")).strip_edges()
	if bool(response.get("talk_to_player", false)) and not dialogue.is_empty():
		ai_spoke.emit(dialogue, mood)

	var fallback_summary = _local_summary(snapshot, response)
	var compression_payload = _compact_interaction_payload(snapshot, response)
	if llm.is_configured():
		var request_id = llm.chat(_compression_messages(compression_payload, fallback_summary), {
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

	if _maybe_request_task_detail(snapshot):
		return
	_finish_brain_cycle()


func _apply_task_detail_response(response: Dictionary, snapshot: Dictionary, task: Dictionary) -> void:
	var follow_signal = _follow_signal_from_response(response)
	if follow_signal != -1:
		ai.set_follow_enabled(follow_signal == 1)

	var memory_ops = response.get("memory_ops", {})
	if typeof(memory_ops) == TYPE_DICTIONARY:
		memory.apply_ai_memory_ops(memory_ops, clock.game_minutes)

	var task_id = str(task.get("id", ""))
	var task_update = response.get("task_update", {})
	var updated_status = ""
	if typeof(task_update) == TYPE_DICTIONARY:
		task_update["id"] = task_id
		updated_status = str(task_update.get("status", "")).strip_edges()
		_update_task(task_update)

	var status = str(response.get("task_status", "")).strip_edges()
	if status.is_empty():
		status = updated_status
	if not status.is_empty():
		_set_task_status(task_id, status, _task_detail_result_text(response))

	if bool(response.get("has_action", false)):
		var action = _action_from_response(response, snapshot)
		if not action.is_empty():
			action = _attach_task_id_to_action(action, task_id)
			_set_task_status(task_id, TASK_STATUS_RUNNING)
			ai.enqueue_action(action)
		elif status.is_empty():
			_set_task_status(task_id, TASK_STATUS_BLOCKED, "task_detail_returned_invalid_action")
	else:
		if status.is_empty():
			_set_task_status(task_id, TASK_STATUS_BLOCKED, "task_detail_returned_no_action")

	_finish_brain_cycle()


func _task_detail_result_text(response: Dictionary) -> String:
	var task_update = response.get("task_update", {})
	if typeof(task_update) == TYPE_DICTIONARY:
		var last_result = str(task_update.get("last_result", "")).strip_edges()
		if not last_result.is_empty():
			return last_result.left(800)
		var notes = str(task_update.get("notes", "")).strip_edges()
		if not notes.is_empty():
			return notes.left(800)
	return ""


func _apply_task_ops(response: Dictionary, snapshot: Dictionary) -> void:
	var task_ops = response.get("task_ops", {})
	if typeof(task_ops) != TYPE_DICTIONARY:
		task_ops = {}

	var changed = false
	if bool(task_ops.get("clear_all", false)):
		_clear_all_tasks("task_plan_clear_all")
		changed = true

	if bool(task_ops.get("stop_current", false)):
		_stop_current_task("task_plan_stop_current")
		changed = true

	var delete_list = task_ops.get("delete", [])
	if typeof(delete_list) == TYPE_ARRAY:
		for item in delete_list:
			changed = _delete_task(item) or changed

	var update_list = task_ops.get("update", [])
	if typeof(update_list) == TYPE_ARRAY:
		for item in update_list:
			if typeof(item) == TYPE_DICTIONARY:
				changed = _update_task(item) or changed

	var add_list = task_ops.get("add", [])
	if typeof(add_list) == TYPE_ARRAY:
		for item in add_list:
			if typeof(item) == TYPE_DICTIONARY:
				var task = _add_task(item, str(snapshot.get("trigger", "planner")))
				changed = (not task.is_empty()) or changed

	if not response.has("task_ops") and bool(response.get("has_action", false)):
		var action_text = JSON.stringify(response.get("action", {}))
		var task = _add_task({
			"title": "执行旧格式动作",
			"objective": "模型返回了旧格式 action，需要根据以下动作意图重新细化执行：" + action_text.left(420),
			"kind": "general",
			"priority": 5,
			"notes": "backward_compat_action_response",
		}, str(snapshot.get("trigger", "legacy_action")))
		changed = (not task.is_empty()) or changed

	if changed:
		_emit_tasks_changed()


func _maybe_request_task_detail(base_snapshot: Dictionary) -> bool:
	if _ai_has_pending_actions():
		return false
	var task = _active_or_next_task()
	if task.is_empty():
		_emit_tasks_changed()
		return false

	var task_id = str(task.get("id", ""))
	_set_task_status(task_id, TASK_STATUS_RUNNING)
	var task_index = _task_index_by_id(task_id)
	if task_index < 0:
		return false
	task = ai_tasks[task_index].duplicate(true)
	task["detail_attempts"] = int(task.get("detail_attempts", 0)) + 1
	task["updated_game_minutes"] = int(clock.game_minutes)
	ai_tasks[task_index] = task
	_emit_tasks_changed()

	var snapshot = _build_task_detail_perception(base_snapshot, task)
	if llm.is_configured():
		var request_id = llm.chat(_task_detail_messages(snapshot, task), {"json_response": true, "temperature": 0.25})
		_pending_task_detail[request_id] = {
			"snapshot": snapshot,
			"task": task,
		}
	else:
		_apply_task_detail_response(_offline_task_detail(snapshot, task), snapshot, task)
	return true


func _build_task_detail_perception(base_snapshot: Dictionary, task: Dictionary) -> Dictionary:
	var detail_snapshot = _build_perception("task_detail", base_snapshot.get("player_messages", []), base_snapshot.get("ai_events", []), base_snapshot.get("player_marked_areas", []))
	detail_snapshot["activation"] = base_snapshot.get("activation", detail_snapshot.get("activation", {}))
	detail_snapshot["task_to_detail"] = task.duplicate(true)
	detail_snapshot["planning_trigger"] = str(base_snapshot.get("trigger", ""))
	detail_snapshot["instruction"] = "Refine task_to_detail into one executable action or task status update using this fresh perception snapshot. This is a silent tool-call layer: do not speak to the player and do not return dialogue/talk_to_player/mood/thought."
	return detail_snapshot


func _attach_task_id_to_action(action: Dictionary, task_id: String) -> Dictionary:
	var result = action.duplicate(true)
	if str(result.get("type", "")) == "sequence":
		var actions = result.get("actions", [])
		if typeof(actions) == TYPE_ARRAY:
			for index in range(actions.size()):
				if typeof(actions[index]) == TYPE_DICTIONARY:
					var item: Dictionary = actions[index]
					item["task_id"] = task_id
					actions[index] = item
			result["actions"] = actions
	result["task_id"] = task_id
	return result


func _finish_brain_cycle() -> void:
	busy = false
	thinking_changed.emit(false)
	if not queued_player_messages.is_empty() or not queued_player_marked_areas.is_empty():
		_request_perception("queued_player_message")
	elif not queued_ai_events.is_empty():
		_request_perception("queued_ai_action_event")


func _offline_task_plan(snapshot: Dictionary) -> Dictionary:
	var player_messages: Array = snapshot.get("player_messages", [])
	var player_marked_areas: Array = snapshot.get("player_marked_areas", [])
	var response = {
		"talk_to_player": false,
		"dialogue": "",
		"set_follow": -1,
		"mood": "calm",
		"thought": "No LLM key is configured, so I am using the local fallback task planner.",
		"task_ops": {"add": [], "update": [], "delete": [], "stop_current": false, "clear_all": false},
		"memory_ops": {"add": [], "update_priority": [], "delete": []},
	}
	if not player_messages.is_empty():
		var joined = " / ".join(player_messages)
		var lower = joined.to_lower()
		response["talk_to_player"] = true
		response["dialogue"] = "我听到了：%s。我们先观察附近，再一起决定下一步。" % joined.left(80)
		if not player_marked_areas.is_empty():
			response["dialogue"] += " 你框选的区域信息我也收到了。"
		response["mood"] = "curious"
		if _text_requests_interrupt(joined, lower):
			response["task_ops"]["stop_current"] = true
			response["dialogue"] = "好，我先停下当前任务。"
		else:
			response["task_ops"]["add"].append(_offline_task_from_text(joined, snapshot))
		response["memory_ops"]["add"].append({
			"summary": "玩家说：" + joined.left(80),
			"priority": 4,
		})
	return response


func _offline_task_from_text(text: String, snapshot: Dictionary) -> Dictionary:
	var lower = text.to_lower()
	var kind = "general"
	var title = text.left(28)
	if lower.contains("gather") or lower.contains("collect") or text.contains("采集") or text.contains("收集"):
		kind = "gather"
	elif text.contains("建") or lower.contains("build"):
		kind = "build"
	elif text.contains("拆") or text.contains("破坏") or lower.contains("destroy"):
		kind = "destroy"
	elif text.contains("找") or text.contains("寻找") or lower.contains("search"):
		kind = "search"
	elif text.contains("去") or text.contains("看看") or lower.contains("go"):
		kind = "move"
	return {
		"title": title if not title.is_empty() else "回应玩家请求",
		"objective": text,
		"kind": kind,
		"priority": 6 if bool(snapshot.get("activation", {}).get("is_player_initiated", false)) else 4,
		"notes": "offline_fallback_task",
	}


func _offline_task_detail(snapshot: Dictionary, task: Dictionary) -> Dictionary:
	var objective = str(task.get("objective", task.get("title", "")))
	var response = {
		"has_action": false,
		"action": {"type": "idle"},
		"set_follow": -1,
		"task_status": TASK_STATUS_RUNNING,
		"task_update": {"status": TASK_STATUS_RUNNING, "notes": "offline_detail"},
		"memory_ops": {"add": [], "update_priority": [], "delete": []},
	}
	var inferred = _infer_action_from_context(snapshot, {"thought": objective})
	if inferred.is_empty():
		response["task_status"] = TASK_STATUS_BLOCKED
		response["task_update"] = {"status": TASK_STATUS_BLOCKED, "last_result": "offline_detail_no_action"}
		return response
	response["has_action"] = true
	response["action"] = inferred
	return response


func _sanitize_ai_event(event: Dictionary) -> Dictionary:
	return {
		"event_type": str(event.get("event_type", "")),
		"action_type": str(event.get("action_type", "")),
		"task_id": str(event.get("task_id", "")),
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


func _update_task_from_ai_event(event: Dictionary) -> void:
	var task_id = str(event.get("task_id", "")).strip_edges()
	if task_id.is_empty():
		task_id = active_task_id
	if task_id.is_empty():
		return
	var index = _task_index_by_id(task_id)
	if index < 0:
		return

	var task: Dictionary = ai_tasks[index]
	var event_type = str(event.get("event_type", ""))
	var status = str(event.get("status", ""))
	var batch_index = int(event.get("batch_index", 1))
	var batch_count = int(event.get("batch_count", 1))
	var final_batch_event = batch_count <= 1 or batch_index >= batch_count

	task["last_result"] = _task_event_summary(event)
	task["updated_game_minutes"] = int(clock.game_minutes)
	if event_type == "action_interrupted":
		task["status"] = TASK_STATUS_CANCELLED
		if active_task_id == task_id:
			active_task_id = ""
	elif event_type.ends_with("_failed") or status == "failed":
		task["status"] = TASK_STATUS_BLOCKED
		if active_task_id == task_id:
			active_task_id = ""
	elif (event_type in ["action_completed", "gather_completed"] or (event_type in ["build_completed", "destroy_completed"] and final_batch_event)) and status != "progress":
		task["status"] = TASK_STATUS_COMPLETED
		if active_task_id == task_id:
			active_task_id = ""
	elif status == "progress" or event_type in ["search_target_found", "movement_unstuck_teleport"]:
		task["status"] = TASK_STATUS_RUNNING

	ai_tasks[index] = task
	_emit_tasks_changed()


func _task_event_summary(event: Dictionary) -> String:
	var event_type = str(event.get("event_type", ""))
	var status = str(event.get("status", ""))
	var target = str(event.get("target", ""))
	var tile_kind = str(event.get("tile_kind", ""))
	var target_tile = event.get("target_tile", event.get("found_tile", []))
	var parts = [event_type]
	if not status.is_empty():
		parts.append(status)
	if not target.is_empty():
		parts.append(target)
	if not tile_kind.is_empty():
		parts.append(tile_kind)
	if typeof(target_tile) == TYPE_ARRAY and target_tile.size() >= 2:
		parts.append("(%d,%d)" % [int(target_tile[0]), int(target_tile[1])])
	var reason = str(event.get("reason", ""))
	if not reason.is_empty():
		parts.append(reason)
	return " ".join(parts).left(180)


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
		"ai_tasks": _compact_ai_tasks(ai_tasks),
		"active_task_id": active_task_id,
		"response": {
			"mood": str(response.get("mood", "calm")),
			"dialogue": str(response.get("dialogue", "")).left(240),
			"thought": str(response.get("thought", "")).left(240),
			"set_follow": _follow_signal_from_response(response),
			"has_action": bool(response.get("has_action", false)),
			"action": response.get("action", {}),
			"task_ops": response.get("task_ops", {}),
			"task_status": str(response.get("task_status", "")),
			"task_update": response.get("task_update", {}),
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


func _compact_ai_tasks(tasks: Array) -> Array:
	var result = []
	for task in tasks:
		if typeof(task) != TYPE_DICTIONARY:
			continue
		result.append({
			"id": str(task.get("id", "")),
			"title": str(task.get("title", "")).left(80),
			"kind": str(task.get("kind", "")),
			"status": str(task.get("status", "")),
			"priority": int(task.get("priority", 5)),
			"last_result": str(task.get("last_result", "")).left(160),
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


func _action_from_response(response: Dictionary, snapshot: Dictionary, allow_infer = false) -> Dictionary:
	var action = response.get("action", {})
	if typeof(action) != TYPE_DICTIONARY:
		return _action_parse_fallback(snapshot, response, allow_infer)

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
		return _action_parse_fallback(snapshot, response, allow_infer)

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
		return _action_parse_fallback(snapshot, response, allow_infer)

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
		return _action_parse_fallback(snapshot, response, allow_infer)

	if type == "build_tile":
		var build_tile = action.get("tile", [])
		if typeof(build_tile) == TYPE_ARRAY and build_tile.size() >= 2:
			return _with_interrupt_flag({
				"type": "build_tile",
				"tile": [int(build_tile[0]), int(build_tile[1])],
				"tile_kind": GameConfig.normalize_build_kind(str(action.get("tile_kind", action.get("kind", "wood_floor")))),
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _action_parse_fallback(snapshot, response, allow_infer)

	if type == "destroy_tiles" or type == "break_tiles" or (type == "destroy_tile" and action.has("tiles")):
		var destroy_actions = _batch_destroy_actions(action)
		if not destroy_actions.is_empty():
			return _with_interrupt_flag({"type": "sequence", "actions": destroy_actions}, action)
		return _action_parse_fallback(snapshot, response, allow_infer)

	if type == "destroy_tile" or type == "break_tile":
		var destroy_tile = action.get("tile", [])
		if typeof(destroy_tile) == TYPE_ARRAY and destroy_tile.size() >= 2:
			return _with_interrupt_flag({
				"type": "destroy_tile",
				"tile": [int(destroy_tile[0]), int(destroy_tile[1])],
				"max_nodes": int(action.get("max_nodes", GameConfig.AI_PATH_MAX_NODES)),
			}, action)
		return _action_parse_fallback(snapshot, response, allow_infer)

	if type == "follow_player":
		return _with_interrupt_flag({"type": "follow_player"}, action)
	if type == "idle":
		return {"type": "idle"}
	return _action_parse_fallback(snapshot, response, allow_infer)


func _action_parse_fallback(snapshot: Dictionary, response: Dictionary, allow_infer: bool) -> Dictionary:
	if allow_infer:
		return _infer_action_from_context(snapshot, response)
	return {}


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

	var wants_gather = lower.contains("gather") or lower.contains("collect") or lower.contains("resource") or text.contains("采集") or text.contains("收集") or text.contains("资源")
	if wants_gather and (lower.contains("stone") or lower.contains("rock") or text.contains("石")):
		return {"type": "gather_resource", "resource": "stone", "amount": 1, "scan_radius": 12, "max_steps": 32, "step_tiles": 8}
	if wants_gather and (lower.contains("wood") or lower.contains("tree") or lower.contains("log") or text.contains("木") or text.contains("树")):
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
			_apply_task_plan_response(parsed, snapshot)
		else:
			debug_event.emit("Task plan JSON parse failed; using fallback.")
			_apply_task_plan_response(_offline_task_plan(snapshot), snapshot)
		return

	if _pending_task_detail.has(request_id):
		var pending_detail: Dictionary = _pending_task_detail[request_id]
		_pending_task_detail.erase(request_id)
		var detail_snapshot: Dictionary = pending_detail.get("snapshot", {})
		var task: Dictionary = pending_detail.get("task", {})
		var parsed_detail = _parse_json_content(str(payload.get("content", "")))
		if typeof(parsed_detail) == TYPE_DICTIONARY:
			_apply_task_detail_response(parsed_detail, detail_snapshot, task)
		else:
			debug_event.emit("Task detail JSON parse failed; using fallback.")
			_apply_task_detail_response(_offline_task_detail(detail_snapshot, task), detail_snapshot, task)
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
		_apply_task_plan_response(_offline_task_plan(snapshot), snapshot)
		return

	if _pending_task_detail.has(request_id):
		var pending_detail: Dictionary = _pending_task_detail[request_id]
		_pending_task_detail.erase(request_id)
		debug_event.emit(error_message)
		var detail_snapshot: Dictionary = pending_detail.get("snapshot", {})
		var task: Dictionary = pending_detail.get("task", {})
		_apply_task_detail_response(_offline_task_detail(detail_snapshot, task), detail_snapshot, task)
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


func _action_result_trigger_perception_enabled() -> bool:
	return _bool_runtime_parameter("ai.action_result_trigger_perception", GameConfig.AI_ACTION_RESULT_TRIGGER_PERCEPTION)


func _memory_recall_count() -> int:
	return int(game_api.get_runtime_parameter("ai.memory_recall_count", GameConfig.MEMORY_RECALL_COUNT))


func _forget_interval() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_interval_game_minutes", GameConfig.FORGET_INTERVAL_GAME_MINUTES))


func _forget_percent() -> float:
	return float(game_api.get_runtime_parameter("ai.forget_percent", GameConfig.FORGET_PERCENT))


func _bool_runtime_parameter(key: String, fallback: bool) -> bool:
	var value = game_api.get_runtime_parameter(key, fallback)
	match typeof(value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT, TYPE_FLOAT:
			return float(value) != 0.0
		TYPE_STRING:
			var lower = str(value).strip_edges().to_lower()
			if ["1", "true", "yes", "on", "开", "开启", "启用"].has(lower):
				return true
			if ["0", "false", "no", "off", "关", "关闭", "禁用"].has(lower):
				return false
	return fallback
