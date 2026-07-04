class_name LLMClient
extends Node

signal completion_ready(request_id, payload)
signal completion_failed(request_id, error_message)

const GameConfig = preload("res://scripts/config/game_config.gd")

var api_base_url = GameConfig.DEFAULT_LLM_BASE_URL
var api_key = ""
var default_model = GameConfig.DEFAULT_LLM_MODEL
var compression_model = GameConfig.DEFAULT_LLM_COMPRESS_MODEL
var request_timeout_seconds = GameConfig.DEFAULT_LLM_TIMEOUT_SECONDS
var max_retries = GameConfig.DEFAULT_LLM_MAX_RETRIES
var retry_delay_seconds = GameConfig.DEFAULT_LLM_RETRY_DELAY_SECONDS
var json_response_override = -1  # -1 = auto (cloud=true, local=false), 0 = force off, 1 = force on

var _next_request_id = 1
var _active_requests = {}


func _ready() -> void:
	_load_local_config()
	_load_environment_config()


func is_configured() -> bool:
	return not api_base_url.is_empty()


func is_local_mode() -> bool:
	return api_key.is_empty()


func chat(messages: Array, options = {}) -> int:
	var request_id = _next_request_id
	_next_request_id += 1

	if not is_configured():
		call_deferred("_emit_unconfigured", request_id)
		return request_id

	var model = str(options.get("model", default_model))
	var body = {
		"model": model,
		"messages": messages,
		"temperature": float(options.get("temperature", 0.35)),
	}
	if _should_send_json_response(options):
		body["response_format"] = {"type": "json_object"}

	_active_requests[request_id] = {
		"body": body,
		"attempt": 0,
	}
	_send_request(request_id)
	return request_id


func _send_request(request_id: int) -> void:
	if not _active_requests.has(request_id):
		return

	var state: Dictionary = _active_requests[request_id]
	state["attempt"] = int(state.get("attempt", 0)) + 1
	_active_requests[request_id] = state

	var http = HTTPRequest.new()
	http.timeout = request_timeout_seconds
	add_child(http)
	http.request_completed.connect(_on_request_completed.bind(request_id, http))

	var headers = ["Content-Type: application/json"]
	if not api_key.is_empty():
		headers.append("Authorization: Bearer %s" % api_key)
	var endpoint = "%s/chat/completions" % api_base_url
	var error = http.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(state["body"]))
	if error != OK:
		http.queue_free()
		_fail_or_retry(request_id, "Failed to start HTTP request: %s" % error, true)


func _emit_unconfigured(request_id: int) -> void:
	completion_failed.emit(request_id, "LLM 未配置。设置 config/llm_config.json 的 api_base_url，或设置 WITHYOU_LLM_API_BASE 环境变量。本地 AI（Ollama 等）只需填写 api_base_url，无需 api_key。")


func _load_local_config() -> void:
	var path = "res://config/llm_config.json"
	if not FileAccess.file_exists(path):
		return
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	api_base_url = str(parsed.get("api_base_url", api_base_url)).trim_suffix("/")
	api_key = str(parsed.get("api_key", api_key))
	default_model = str(parsed.get("model", default_model))
	compression_model = str(parsed.get("compression_model", compression_model))
	request_timeout_seconds = float(parsed.get("timeout_seconds", request_timeout_seconds))
	max_retries = int(parsed.get("max_retries", max_retries))
	retry_delay_seconds = float(parsed.get("retry_delay_seconds", retry_delay_seconds))
	if parsed.has("json_response"):
		json_response_override = 1 if bool(parsed["json_response"]) else 0
	_clamp_transport_settings()


func _load_environment_config() -> void:
	var env_base = OS.get_environment("WITHYOU_LLM_API_BASE")
	var env_key = OS.get_environment("WITHYOU_LLM_API_KEY")
	var env_model = OS.get_environment("WITHYOU_LLM_MODEL")
	var env_compress_model = OS.get_environment("WITHYOU_LLM_COMPRESS_MODEL")
	var env_timeout = OS.get_environment("WITHYOU_LLM_TIMEOUT_SECONDS")
	var env_retries = OS.get_environment("WITHYOU_LLM_MAX_RETRIES")
	var env_retry_delay = OS.get_environment("WITHYOU_LLM_RETRY_DELAY_SECONDS")
	var env_json_response = OS.get_environment("WITHYOU_LLM_JSON_RESPONSE")
	if not env_base.is_empty():
		api_base_url = env_base.trim_suffix("/")
	if not env_key.is_empty():
		api_key = env_key
	if not env_model.is_empty():
		default_model = env_model
	if not env_compress_model.is_empty():
		compression_model = env_compress_model
	if not env_timeout.is_empty():
		request_timeout_seconds = float(env_timeout)
	if not env_retries.is_empty():
		max_retries = int(env_retries)
	if not env_retry_delay.is_empty():
		retry_delay_seconds = float(env_retry_delay)
	if not env_json_response.is_empty():
		json_response_override = 1 if env_json_response.strip_edges().to_lower() in ["1", "true", "yes"] else 0
	_clamp_transport_settings()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request_id: int, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail_or_retry(request_id, "HTTP request failed: %s" % _http_result_label(result), _is_retryable_result(result))
		return
	if response_code < 200 or response_code >= 300:
		_fail_or_retry(request_id, "HTTP %s: %s" % [response_code, body.get_string_from_utf8()], _is_retryable_status(response_code))
		return

	_active_requests.erase(request_id)
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		completion_failed.emit(request_id, "LLM response was not a JSON object.")
		return

	var choices = parsed.get("choices", [])
	if choices.is_empty():
		completion_failed.emit(request_id, "LLM response did not contain choices.")
		return

	var message = choices[0].get("message", {})
	completion_ready.emit(request_id, {
		"content": str(message.get("content", "")),
		"raw": parsed,
	})


func _fail_or_retry(request_id: int, message: String, retryable: bool) -> void:
	if not _active_requests.has(request_id):
		completion_failed.emit(request_id, message)
		return

	var state: Dictionary = _active_requests[request_id]
	var attempt = int(state.get("attempt", 1))
	if retryable and attempt <= max_retries:
		var delay = retry_delay_seconds * float(attempt)
		get_tree().create_timer(delay).timeout.connect(func(): _send_request(request_id))
		return

	_active_requests.erase(request_id)
	var attempts = attempt
	completion_failed.emit(request_id, "%s after %d attempt(s)" % [message, attempts])


func _is_retryable_result(result: int) -> bool:
	return [
		HTTPRequest.RESULT_CANT_CONNECT,
		HTTPRequest.RESULT_CANT_RESOLVE,
		HTTPRequest.RESULT_CONNECTION_ERROR,
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR,
		HTTPRequest.RESULT_NO_RESPONSE,
		HTTPRequest.RESULT_REQUEST_FAILED,
		HTTPRequest.RESULT_TIMEOUT,
	].has(result)


func _is_retryable_status(response_code: int) -> bool:
	return response_code == 429 or response_code == 500 or response_code == 502 or response_code == 503 or response_code == 504


func _http_result_label(result: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			return "RESULT_SUCCESS (0)"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
			return "RESULT_CHUNKED_BODY_SIZE_MISMATCH (1)"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "RESULT_CANT_CONNECT (2)"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "RESULT_CANT_RESOLVE (3)"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "RESULT_CONNECTION_ERROR (4)"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "RESULT_TLS_HANDSHAKE_ERROR (5)"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "RESULT_NO_RESPONSE (6)"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "RESULT_BODY_SIZE_LIMIT_EXCEEDED (7)"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "RESULT_BODY_DECOMPRESS_FAILED (8)"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "RESULT_REQUEST_FAILED (9)"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
			return "RESULT_DOWNLOAD_FILE_CANT_OPEN (10)"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "RESULT_DOWNLOAD_FILE_WRITE_ERROR (11)"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "RESULT_REDIRECT_LIMIT_REACHED (12)"
		HTTPRequest.RESULT_TIMEOUT:
			return "RESULT_TIMEOUT (13)"
		_:
			return "UNKNOWN_RESULT (%d)" % result


func _clamp_transport_settings() -> void:
	request_timeout_seconds = clamp(request_timeout_seconds, 10.0, 300.0)
	max_retries = clamp(max_retries, 0, 5)
	retry_delay_seconds = clamp(retry_delay_seconds, 0.25, 30.0)


func _json_response_default() -> bool:
	if json_response_override == 1:
		return true
	if json_response_override == 0:
		return false
	return not is_local_mode()


func _should_send_json_response(options: Dictionary) -> bool:
	if json_response_override == 1:
		return true
	if json_response_override == 0:
		return false
	if options.has("json_response"):
		return bool(options["json_response"])
	return not is_local_mode()
