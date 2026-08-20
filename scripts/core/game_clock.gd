class_name GameClock
extends Node

signal game_minute_changed(current_minutes)

const GameConfig = preload("res://scripts/config/game_config.gd")

var game_minutes = GameConfig.START_GAME_MINUTES
var minutes_per_real_second = GameConfig.GAME_MINUTES_PER_REAL_SECOND
var running = false

var _last_whole_minute = -1


func set_running(value: bool) -> void:
	running = value


func _process(delta: float) -> void:
	if not running:
		return
	game_minutes += delta * minutes_per_real_second
	var whole_minute = int(floor(game_minutes))
	if whole_minute != _last_whole_minute:
		_last_whole_minute = whole_minute
		game_minute_changed.emit(game_minutes)


func reset(minutes = GameConfig.START_GAME_MINUTES) -> void:
	game_minutes = minutes
	_last_whole_minute = int(floor(game_minutes))
	game_minute_changed.emit(game_minutes)


func get_save_data() -> Dictionary:
	return {
		"game_minutes": game_minutes,
		"minutes_per_real_second": minutes_per_real_second,
	}


func apply_save_data(data: Dictionary) -> void:
	minutes_per_real_second = float(data.get("minutes_per_real_second", GameConfig.GAME_MINUTES_PER_REAL_SECOND))
	reset(float(data.get("game_minutes", GameConfig.START_GAME_MINUTES)))


func format_game_time() -> String:
	var total_minutes = int(floor(game_minutes)) % (24 * 60)
	var hour = total_minutes / 60
	var minute = total_minutes % 60
	return "%02d:%02d" % [hour, minute]


func snapshot() -> Dictionary:
	return {
		"game_minutes": game_minutes,
		"game_time": format_game_time(),
		"minutes_per_real_second": minutes_per_real_second,
		"system_time": Time.get_datetime_string_from_system(false, true),
	}
