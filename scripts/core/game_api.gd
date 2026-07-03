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
		"ai.perception_interval_game_minutes": GameConfig.PERCEPTION_INTERVAL_GAME_MINUTES,
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
