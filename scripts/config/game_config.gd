class_name GameConfig
extends RefCounted

const TILE_SIZE = 16
const CITY_SIZE = 99
const CITY_HALF_SIZE = 49

const DEFAULT_WORLD_SEED = 47029
const START_GAME_MINUTES = 8.0 * 60.0
const GAME_MINUTES_PER_REAL_SECOND = 1.0

const PLAYER_SPEED = 96.0
const AI_SPEED = 78.0
const CAMERA_ZOOM = Vector2(2.5, 2.5)

const DEFAULT_RESOLUTION = Vector2i(1920, 1080)
const RESOLUTION_OPTIONS = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

const PERCEPTION_INTERVAL_GAME_MINUTES = 60.0
const RECENT_HISTORY_LIMIT = 12
const MEMORY_RECALL_COUNT = 8
const FORGET_INTERVAL_GAME_MINUTES = 60.0
const FORGET_PERCENT = 0.01

const DEFAULT_LLM_BASE_URL = "https://api.openai.com/v1"
const DEFAULT_LLM_MODEL = "gpt-4.1-mini"
const DEFAULT_LLM_COMPRESS_MODEL = "gpt-4.1-mini"
const DEFAULT_LLM_TIMEOUT_SECONDS = 120.0
const DEFAULT_LLM_MAX_RETRIES = 2
const DEFAULT_LLM_RETRY_DELAY_SECONDS = 2.0

const MOODS = ["calm", "happy", "curious", "worried", "tired", "angry", "disappointed", "sad", "annoyed", "afraid"]


static func llm_base_url() -> String:
	var value = OS.get_environment("WITHYOU_LLM_API_BASE")
	return DEFAULT_LLM_BASE_URL if value.is_empty() else value.trim_suffix("/")


static func llm_api_key() -> String:
	return OS.get_environment("WITHYOU_LLM_API_KEY")


static func llm_model() -> String:
	var value = OS.get_environment("WITHYOU_LLM_MODEL")
	return DEFAULT_LLM_MODEL if value.is_empty() else value


static func llm_compress_model() -> String:
	var value = OS.get_environment("WITHYOU_LLM_COMPRESS_MODEL")
	return DEFAULT_LLM_COMPRESS_MODEL if value.is_empty() else value
