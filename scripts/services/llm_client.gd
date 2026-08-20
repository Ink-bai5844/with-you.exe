class_name LLMClient
extends Node

signal completion_ready(request_id, payload)
signal completion_failed(request_id, error_message)
signal stream_started(request_id, info)
signal stream_delta(request_id, text, channel)

const GameConfig = preload("res://scripts/config/game_config.gd")

var api_base_url = GameConfig.DEFAULT_LLM_BASE_URL
var api_key = ""
var default_model = GameConfig.DEFAULT_LLM_MODEL
var compression_model = GameConfig.DEFAULT_LLM_COMPRESS_MODEL
var request_timeout_seconds = GameConfig.DEFAULT_LLM_TIMEOUT_SECONDS
var max_retries = GameConfig.DEFAULT_LLM_MAX_RETRIES
var retry_delay_seconds = GameConfig.DEFAULT_LLM_RETRY_DELAY_SECONDS
var json_response_enabled = true
var stream_enabled = true

var _next_request_id = 1
var _active_requests = {}


func _ready() -> void:
	_load_local_config()
	_load_environment_config()


func is_configured() -> bool:
	return not api_key.is_empty() and not api_base_url.is_empty()


func chat(messages: Array, options = {}) -> int:
	var request_id = _next_request_id
	_next_request_id += 1

	if not is_configured():
		call_deferred("_emit_unconfigured", request_id)
		return request_id

	var model = str(options.get("model", default_model))
	var want_json = bool(options.get("json_response", json_response_enabled))
	var want_stream = bool(options.get("stream", stream_enabled))
	var body = {
		"model": model,
		"messages": messages,
		"temperature": float(options.get("temperature", 0.35)),
		"stream": want_stream,
	}
	if want_json:
		body["response_format"] = {"type": "json_object"}

	_active_requests[request_id] = {
		"body": body,
		"attempt": 0,
		"info": {
			"model": model,
			"layer": str(options.get("layer", "")),
			"title": str(options.get("title", "LLM")),
			"summary": str(options.get("summary", "")),
		},
		"use_stream": want_stream,
		"want_json": want_json,
		"dropped_json": false,
		"dropped_stream": false,
	}
	if want_stream:
		_start_stream(request_id)
	else:
		_send_blocking_request(request_id)
	return request_id


func _process(_delta: float) -> void:
	var ids = _active_requests.keys()
	for request_id in ids:
		_poll_stream(int(request_id))


func _start_stream(request_id: int) -> void:
	if not _active_requests.has(request_id):
		return

	var state: Dictionary = _active_requests[request_id]
	if not bool(state.get("compat_retry", false)):
		state["attempt"] = int(state.get("attempt", 0)) + 1
	state["compat_retry"] = false
	var endpoint = _parse_endpoint()
	var client = HTTPClient.new()
	var tls_options = TLSOptions.client() if bool(endpoint.get("tls", true)) else null
	var error = client.connect_to_host(str(endpoint.get("host", "")), int(endpoint.get("port", 443)), tls_options)
	if error != OK:
		_fallback_or_fail(request_id, "无法连接 LLM 主机：%s" % error, true)
		return

	state["client"] = client
	state["path"] = str(endpoint.get("path", "/chat/completions"))
	state["phase"] = "connecting"
	state["request_sent"] = false
	state["headers_checked"] = false
	state["error_mode"] = false
	state["buffer"] = ""
	state["content"] = ""
	state["reasoning"] = ""
	state["started_msec"] = Time.get_ticks_msec()
	_active_requests[request_id] = state
	stream_started.emit(request_id, state.get("info", {}))


func _poll_stream(request_id: int) -> void:
	if not _active_requests.has(request_id):
		return
	var state: Dictionary = _active_requests[request_id]
	var client = state.get("client", null)
	if client == null:
		return

	var elapsed = (Time.get_ticks_msec() - int(state.get("started_msec", 0))) / 1000.0
	if elapsed > request_timeout_seconds:
		_close_client(state)
		_fallback_or_fail(request_id, "LLM 流式请求超时", true)
		return

	var poll_error = client.poll()
	if poll_error != OK and client.get_status() == HTTPClient.STATUS_CONNECTION_ERROR:
		_close_client(state)
		_fallback_or_fail(request_id, "LLM 连接中断", true)
		return

	var status = client.get_status()
	if elapsed > 8.0 and status in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		_close_client(state)
		_fallback_or_fail(request_id, "连接 OpenCode 超时（8 秒）。请检查网络能否访问 opencode.ai。", false)
		return
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if bool(state.get("request_sent", false)):
				return
			var headers = PackedStringArray([
				"Content-Type: application/json",
				"Authorization: Bearer %s" % api_key,
				"Accept: text/event-stream",
			])
			var error = client.request(HTTPClient.METHOD_POST, str(state.get("path", "/chat/completions")), headers, JSON.stringify(state.get("body", {})))
			if error != OK:
				_close_client(state)
				_fallback_or_fail(request_id, "无法发送 LLM 请求：%s" % error, true)
				return
			state["request_sent"] = true
			_active_requests[request_id] = state
		HTTPClient.STATUS_BODY:
			_read_stream_body(request_id, state, client)
		HTTPClient.STATUS_DISCONNECTED:
			_finish_disconnected(request_id, state)
		HTTPClient.STATUS_CANT_RESOLVE:
			_close_client(state)
			_fallback_or_fail(request_id, "无法解析 LLM 主机", true)
		HTTPClient.STATUS_CANT_CONNECT:
			_close_client(state)
			_fallback_or_fail(request_id, "无法连接到 LLM 服务", true)
		HTTPClient.STATUS_CONNECTION_ERROR:
			_close_client(state)
			_fallback_or_fail(request_id, "LLM 连接错误", true)
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_close_client(state)
			_fallback_or_fail(request_id, "LLM TLS 握手失败", true)


func _read_stream_body(request_id: int, state: Dictionary, client: HTTPClient) -> void:
	if not bool(state.get("headers_checked", false)):
		state["headers_checked"] = true
		var code = client.get_response_code()
		state["response_code"] = code
		if code < 200 or code >= 300:
			state["error_mode"] = true
		_active_requests[request_id] = state

	var chunk = client.read_response_body_chunk()
	if chunk.is_empty():
		return
	state["buffer"] = str(state.get("buffer", "")) + chunk.get_string_from_utf8()
	if bool(state.get("error_mode", false)):
		_active_requests[request_id] = state
		return
	_consume_sse_buffer(request_id, state)
	_active_requests[request_id] = state


func _consume_sse_buffer(request_id: int, state: Dictionary) -> void:
	var buffer = str(state.get("buffer", ""))
	if not buffer.contains("data:") and buffer.strip_edges().begins_with("{"):
		return

	var newline = buffer.find("\n")
	while newline >= 0:
		var line = buffer.substr(0, newline).strip_edges()
		buffer = buffer.substr(newline + 1)
		if line.begins_with("data:"):
			var payload = line.substr(5).strip_edges()
			if payload == "[DONE]":
				state["buffer"] = buffer
				_finish_stream_success(request_id, state)
				return
			_apply_sse_payload(request_id, state, payload)
		newline = buffer.find("\n")
	state["buffer"] = buffer


func _apply_sse_payload(request_id: int, state: Dictionary, payload: String) -> void:
	var parsed = JSON.parse_string(payload)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	if parsed.has("error"):
		var err = parsed.get("error", {})
		var message = str(err.get("message", err)) if typeof(err) == TYPE_DICTIONARY else str(err)
		_close_client(state)
		_fallback_or_fail(request_id, message, false)
		return
	var choices = parsed.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return
	var choice = choices[0]
	if typeof(choice) != TYPE_DICTIONARY:
		return
	var delta = choice.get("delta", {})
	if typeof(delta) != TYPE_DICTIONARY:
		delta = choice.get("message", {})
	if typeof(delta) != TYPE_DICTIONARY:
		return

	var reasoning = _delta_text(delta.get("reasoning_content", null))
	if reasoning.is_empty():
		reasoning = _delta_text(delta.get("reasoning", null))
	if not reasoning.is_empty():
		state["reasoning"] = str(state.get("reasoning", "")) + reasoning
		stream_delta.emit(request_id, reasoning, "reasoning")
	var content = _delta_text(delta.get("content", null))
	if not content.is_empty():
		state["content"] = str(state.get("content", "")) + content
		stream_delta.emit(request_id, content, "content")


func _finish_disconnected(request_id: int, state: Dictionary) -> void:
	var buffer = str(state.get("buffer", "")).strip_edges()
	if bool(state.get("error_mode", false)):
		var code = int(state.get("response_code", 0))
		_close_client(state)
		_fallback_or_fail(request_id, "HTTP %s：%s" % [code, buffer.left(240)], _is_retryable_status(code))
		return
	if str(state.get("content", "")).is_empty() and buffer.begins_with("{"):
		var parsed = JSON.parse_string(buffer)
		if typeof(parsed) == TYPE_DICTIONARY:
			var choices = parsed.get("choices", [])
			if typeof(choices) == TYPE_ARRAY and not choices.is_empty():
				var message = choices[0].get("message", {})
				state["content"] = _delta_text(message.get("content", null))
				state["reasoning"] = _delta_text(message.get("reasoning_content", null))
				if str(state["reasoning"]).is_empty():
					state["reasoning"] = _delta_text(message.get("reasoning", null))
				if not str(state["reasoning"]).is_empty():
					stream_delta.emit(request_id, str(state["reasoning"]), "reasoning")
				if not str(state["content"]).is_empty():
					stream_delta.emit(request_id, str(state["content"]), "content")
	if str(state.get("content", "")).is_empty() and not buffer.is_empty() and not buffer.contains("data:"):
		_close_client(state)
		_fallback_or_fail(request_id, "LLM 流式响应无法解析", true)
		return
	_finish_stream_success(request_id, state)


func _finish_stream_success(request_id: int, state: Dictionary) -> void:
	var content = str(state.get("content", "")).replace("<null>", "")
	var reasoning = str(state.get("reasoning", "")).replace("<null>", "")
	_close_client(state)
	if content.strip_edges().is_empty():
		_active_requests[request_id] = state
		_fallback_or_fail(request_id, "LLM 流式响应为空。", false)
		return
	_active_requests.erase(request_id)
	completion_ready.emit(request_id, {
		"content": content,
		"reasoning": reasoning,
		"raw": {},
	})


func _fallback_or_fail(request_id: int, message: String, retryable: bool) -> void:
	var pretty = _humanize_error(message)
	if not _active_requests.has(request_id):
		completion_failed.emit(request_id, pretty)
		return
	var state: Dictionary = _active_requests[request_id]
	var body: Dictionary = state.get("body", {})
	if typeof(body) != TYPE_DICTIONARY:
		body = {}
	var code = int(state.get("response_code", 0))
	var lower = message.to_lower()
	if code in [401, 403] or lower.contains("regionerror") or lower.contains("invalid api key") or lower.contains("unauthorized"):
		_active_requests.erase(request_id)
		completion_failed.emit(request_id, pretty)
		return
	var format_rejected = code in [400, 422] or lower.contains("response_format") or lower.contains("json_object") or lower.contains("json mode")
	if format_rejected and not bool(state.get("dropped_json", false)) and body.has("response_format"):
		body.erase("response_format")
		state["body"] = body
		state["dropped_json"] = true
		state["compat_retry"] = true
		_active_requests[request_id] = state
		if bool(state.get("use_stream", true)) and not bool(state.get("dropped_stream", false)):
			_start_stream(request_id)
		else:
			_send_blocking_request(request_id)
		return
	if bool(state.get("use_stream", true)) and not bool(state.get("dropped_stream", false)):
		state["dropped_stream"] = true
		state["use_stream"] = false
		if body.has("stream"):
			body["stream"] = false
		state["body"] = body
		_active_requests[request_id] = state
		_send_blocking_request(request_id)
		return
	var attempt = int(state.get("attempt", 1))
	if retryable and attempt <= max_retries:
		var delay = retry_delay_seconds * float(attempt)
		get_tree().create_timer(delay).timeout.connect(func():
			if _active_requests.has(request_id):
				if bool(_active_requests[request_id].get("use_stream", true)):
					_start_stream(request_id)
				else:
					_send_blocking_request(request_id)
		)
		return
	_active_requests.erase(request_id)
	completion_failed.emit(request_id, pretty)


func _send_blocking_request(request_id: int) -> void:
	if not _active_requests.has(request_id):
		return
	var state: Dictionary = _active_requests[request_id]
	var body: Dictionary = state.get("body", {})
	body = body.duplicate(true)
	body["stream"] = false
	state["body"] = body
	_active_requests[request_id] = state
	stream_started.emit(request_id, state.get("info", {}))

	var http = HTTPRequest.new()
	http.timeout = request_timeout_seconds
	add_child(http)
	http.request_completed.connect(_on_request_completed.bind(request_id, http))
	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key,
	]
	var endpoint = "%s/chat/completions" % api_base_url
	var error = http.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		http.queue_free()
		_active_requests.erase(request_id)
		completion_failed.emit(request_id, "Failed to start HTTP request: %s" % error)


func _emit_unconfigured(request_id: int) -> void:
	completion_failed.emit(request_id, "LLM is not configured. Set WITHYOU_LLM_API_KEY and optional WITHYOU_LLM_API_BASE.")


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
		json_response_enabled = bool(parsed.get("json_response", true))
	if parsed.has("stream"):
		stream_enabled = bool(parsed.get("stream", true))
	_clamp_transport_settings()


func _load_environment_config() -> void:
	var env_base = OS.get_environment("WITHYOU_LLM_API_BASE")
	var env_key = OS.get_environment("WITHYOU_LLM_API_KEY")
	var env_model = OS.get_environment("WITHYOU_LLM_MODEL")
	var env_compress_model = OS.get_environment("WITHYOU_LLM_COMPRESS_MODEL")
	var env_timeout = OS.get_environment("WITHYOU_LLM_TIMEOUT_SECONDS")
	var env_retries = OS.get_environment("WITHYOU_LLM_MAX_RETRIES")
	var env_retry_delay = OS.get_environment("WITHYOU_LLM_RETRY_DELAY_SECONDS")
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
	_clamp_transport_settings()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request_id: int, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail_blocking(request_id, "HTTP request failed: %s" % _http_result_label(result), _is_retryable_result(result))
		return
	if response_code < 200 or response_code >= 300:
		_fail_blocking(request_id, "HTTP %s: %s" % [response_code, body.get_string_from_utf8()], _is_retryable_status(response_code))
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
	var content = _delta_text(message.get("content", null))
	var reasoning = _delta_text(message.get("reasoning_content", null))
	if reasoning.is_empty():
		reasoning = _delta_text(message.get("reasoning", null))
	if not reasoning.is_empty():
		stream_delta.emit(request_id, reasoning, "reasoning")
	if not content.is_empty():
		stream_delta.emit(request_id, content, "content")
	completion_ready.emit(request_id, {
		"content": content,
		"reasoning": reasoning,
		"raw": parsed,
	})


func _fail_blocking(request_id: int, message: String, retryable: bool) -> void:
	var pretty = _humanize_error(message)
	if not _active_requests.has(request_id):
		completion_failed.emit(request_id, pretty)
		return
	var lower = message.to_lower()
	if message.contains("HTTP 401") or message.contains("HTTP 403") or lower.contains("regionerror"):
		_active_requests.erase(request_id)
		completion_failed.emit(request_id, pretty)
		return
	var state: Dictionary = _active_requests[request_id]
	var attempt = int(state.get("attempt", 1))
	if retryable and attempt <= max_retries:
		var delay = retry_delay_seconds * float(attempt)
		get_tree().create_timer(delay).timeout.connect(func(): _send_blocking_request(request_id))
		return
	_active_requests.erase(request_id)
	completion_failed.emit(request_id, pretty)


func _parse_endpoint() -> Dictionary:
	var raw = api_base_url.strip_edges().trim_suffix("/")
	var tls = true
	if raw.begins_with("https://"):
		raw = raw.substr(8)
		tls = true
	elif raw.begins_with("http://"):
		raw = raw.substr(7)
		tls = false
	var slash = raw.find("/")
	var host_port = raw if slash < 0 else raw.substr(0, slash)
	var base_path = "" if slash < 0 else raw.substr(slash)
	var host = host_port
	var port = 443 if tls else 80
	if host_port.contains(":"):
		var parts = host_port.split(":")
		host = parts[0]
		port = int(parts[1])
	return {
		"host": host,
		"port": port,
		"tls": tls,
		"path": base_path + "/chat/completions",
	}


func _humanize_error(message: String) -> String:
	var json_start = message.find("{")
	var parsed = null
	if json_start >= 0:
		parsed = JSON.parse_string(message.substr(json_start))
	var error_type = ""
	var error_text = message
	if typeof(parsed) == TYPE_DICTIONARY:
		var inner = parsed.get("error", parsed)
		if typeof(inner) == TYPE_DICTIONARY:
			error_type = str(inner.get("type", parsed.get("type", "")))
			error_text = str(inner.get("message", error_text))
		elif typeof(parsed.get("message", null)) == TYPE_STRING:
			error_text = str(parsed.get("message", error_text))
	var lower_type = error_type.to_lower()
	var lower_text = error_text.to_lower()
	if lower_type == "regionerror" or lower_text.contains("hosted in china") or lower_text.contains("explicit opt in"):
		var url = _extract_url(error_text)
		var lines = [
			"OpenCode Go 拒绝了当前模型（RegionError）。",
			"deepseek-v4-flash 最新版只在中国节点，需要先在控制台开通中国托管。",
		]
		if not url.is_empty():
			lines.append("开通地址：%s" % url)
		lines.append("也可以把 model 改成 glm-5.2、kimi-k2.7-code 或 mimo-v2.5。")
		return "\n".join(lines)
	if lower_text.contains("unauthorized") or message.contains("HTTP 401"):
		return "OpenCode 认证失败（401）。请确认 llm_config.json 里的 api_key 是 Go 订阅密钥，api_base_url 为 https://opencode.ai/zen/go/v1。"
	if message.contains("HTTP 404") or lower_text.contains("not found"):
		return "模型或接口不存在（404）。Go 的 chat/completions 模型 id 例如 deepseek-v4-flash、glm-5.2、kimi-k2.7-code。 grok / gpt-5.6-luna 不能走这个接口。"
	return error_text if error_text.length() < 500 else message.left(400)


func _extract_url(text: String) -> String:
	var start = text.find("https://")
	if start < 0:
		return ""
	var end = start
	while end < text.length():
		var ch = text.substr(end, 1)
		if ch.strip_edges().is_empty() or ch in [">", "\"", "'", ")", "]", ","]:
			break
		end += 1
	return text.substr(start, end - start)


func _delta_text(value) -> String:
	if typeof(value) != TYPE_STRING:
		return ""
	if value == "<null>" or value == "null":
		return ""
	return value


func _close_client(state: Dictionary) -> void:
	var client = state.get("client", null)
	if client != null:
		client.close()
	state["client"] = null


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
