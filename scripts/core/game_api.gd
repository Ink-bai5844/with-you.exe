class_name GameAPI
extends Node

signal runtime_parameter_changed(key, value)

const GameConfig = preload("res://scripts/config/game_config.gd")

var runtime_parameters = {}
var _providers = {}


func _ready() -> void:
	runtime_parameters = {
		"world.tile_size": GameConfig.TILE_SIZE,
		"world.city_size": GameConfig.CITY_SIZE,
		"world.terrain_tile_kinds": GameConfig.TERRAIN_TILE_KINDS,
		"world.blocking_tile_kinds": GameConfig.BLOCKING_TILE_KINDS,
		"player.build_radius": GameConfig.PLAYER_BUILD_RADIUS,
		"ai.perception_interval_game_minutes": GameConfig.PERCEPTION_INTERVAL_GAME_MINUTES,
		"ai.perception_map_tile_size": GameConfig.PERCEPTION_MAP_TILE_SIZE,
		"ai.perception_ray_tile_length": GameConfig.PERCEPTION_RAY_TILE_LENGTH,
		"ai.action_result_trigger_perception": GameConfig.AI_ACTION_RESULT_TRIGGER_PERCEPTION,
		"ai.inventory_view_distance_tiles": GameConfig.AI_INVENTORY_VIEW_DISTANCE_TILES,
		"ai.item_transfer_distance_tiles": GameConfig.AI_ITEM_TRANSFER_DISTANCE_TILES,
		"ai.follow_teleport_distance": GameConfig.AI_FOLLOW_TELEPORT_DISTANCE,
		"ai.follow_stuck_seconds": GameConfig.AI_FOLLOW_STUCK_SECONDS,
		"ai.follow_stuck_min_speed": GameConfig.AI_FOLLOW_STUCK_MIN_SPEED,
		"ai.follow_teleport_search_radius": GameConfig.AI_FOLLOW_TELEPORT_SEARCH_RADIUS,
		"ai.follow_teleport_cooldown_seconds": GameConfig.AI_FOLLOW_TELEPORT_COOLDOWN_SECONDS,
		"ai.move_stuck_seconds": GameConfig.AI_MOVE_STUCK_SECONDS,
		"ai.move_stuck_min_speed": GameConfig.AI_MOVE_STUCK_MIN_SPEED,
		"ai.move_teleport_search_radius": GameConfig.AI_MOVE_TELEPORT_SEARCH_RADIUS,
		"ai.move_teleport_cooldown_seconds": GameConfig.AI_MOVE_TELEPORT_COOLDOWN_SECONDS,
		"ai.recent_history_limit": GameConfig.RECENT_HISTORY_LIMIT,
		"ai.memory_recall_count": GameConfig.MEMORY_RECALL_COUNT,
		"ai.forget_interval_game_minutes": GameConfig.FORGET_INTERVAL_GAME_MINUTES,
		"ai.forget_percent": GameConfig.FORGET_PERCENT,
		"time.game_minutes_per_real_second": GameConfig.GAME_MINUTES_PER_REAL_SECOND,
	}


func register_provider(name: String, provider: Callable) -> void:
	_providers[name] = provider


func set_runtime_parameter(key: String, value) -> void:
	runtime_parameters[key] = value
	runtime_parameter_changed.emit(key, value)


func get_runtime_parameter(key: String, fallback = null):
	return runtime_parameters.get(key, fallback)


func snapshot() -> Dictionary:
	var data = {
		"runtime_parameters": runtime_parameters.duplicate(true),
		"providers": {},
	}
	for key in _providers.keys():
		var provider: Callable = _providers[key]
		if provider.is_valid():
			data["providers"][key] = provider.call()
	return data
