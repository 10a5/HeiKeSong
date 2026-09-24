extends SceneTree
## Loopback-only transport tests. They exercise a real HTTPRequest against a
## tiny TCP server, so no external model, network access, or API key is used.

const BRIDGE = preload("res://llm_bridge.gd")

class MockHttpServer extends Node:
	var tcp := TCPServer.new()
	var port := 0
	var received_bodies: Array[String] = []
	var received_paths: Array[String] = []
	var received_headers: Array[String] = []
	var responses: Array[Dictionary] = []
	var peers: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(19760, 19820):
			if tcp.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				set_process(true)
				return true
		return false

	func stop() -> void:
		tcp.stop()
		for item: Dictionary in peers:
			var peer: StreamPeerTCP = item["peer"]
			peer.disconnect_from_host()
		peers.clear()

	func queue_json(status_code: int, body: Dictionary) -> void:
		responses.append({"status": status_code, "body": JSON.stringify(body)})

	func queue_text(status_code: int, body: String) -> void:
		responses.append({"status": status_code, "body": body})

	func _process(_delta: float) -> void:
		if tcp.is_connection_available():
			peers.append({"peer": tcp.take_connection(), "buffer": ""})
		for index in range(peers.size() - 1, -1, -1):
			var item: Dictionary = peers[index]
			var peer: StreamPeerTCP = item["peer"]
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				peers.remove_at(index)
				continue
			var available := peer.get_available_bytes()
			if available <= 0:
				continue
			item["buffer"] = str(item["buffer"]) + peer.get_utf8_string(available)
			var buffer := str(item["buffer"])
			var separator := buffer.find("\r\n\r\n")
			if separator < 0:
				continue
			var headers := buffer.substr(0, separator)
			var body := buffer.substr(separator + 4)
			var expected := 0
			for line in headers.split("\r\n"):
				if line.to_lower().begins_with("content-length:"):
					expected = int(line.get_slice(":", 1).strip_edges())
			if body.to_utf8_buffer().size() < expected:
				continue
			received_bodies.append(body)
			received_headers.append(headers)
			received_paths.append(headers.get_slice("\r\n", 0).get_slice(" ", 1))
			var response := {"status": 200, "body": "{}"}
			if not responses.is_empty():
				response = responses.pop_front()
			if bool(response.get("silent", false)):
				item["buffer"] = ""
				continue
			var response_body := str(response["body"])
			var wire := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [int(response["status"]), "OK" if int(response["status"]) < 400 else "Bad Request", response_body.to_utf8_buffer().size(), response_body]
			peer.put_data(wire.to_utf8_buffer())
			peer.disconnect_from_host()
			peers.remove_at(index)


var passed := 0
var failed := 0
var last_error := ""
var last_summary := ""
var last_directive: Dictionary = {}
var received_summaries := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var server := MockHttpServer.new()
	root.add_child(server)
	_check(server.start(), "loopback mock server started")
	if FileAccess.file_exists("res://key.txt"):
		var auto_bridge := BRIDGE.new()
		root.add_child(auto_bridge)
		await process_frame
		_check(auto_bridge.is_configured(), "key.txt 自动配置 EvoMap（仅验证状态，不输出密钥）")
		_check(str(auto_bridge.config_path).ends_with("key.txt"), "自动配置来源标记为 key.txt")
		auto_bridge.queue_free()
	var bridge := BRIDGE.new()
	_check(not bridge.is_configured(), "新桥接器默认为未配置")
	# Suppress automatic loading of a real user's config. Tests must never send
	# a request to their configured model, even when that config already exists.
	bridge.configure({"enabled": false})
	root.add_child(bridge)
	bridge.summary_received.connect(func(summary: String, directive: Dictionary):
		last_summary = summary
		last_directive = directive.duplicate(true)
		received_summaries += 1)
	bridge.request_failed.connect(func(message: String): last_error = message)
	await process_frame
	_check(not bridge.is_configured(), "测试与已有用户配置隔离且不假装连接")
	_check(not bridge.request_summary({"world_model": {"confidence": 0.4}}), "未配置时不会发送请求")

	var endpoint := "http://127.0.0.1:%d/api/chat" % server.port
	_check(bridge.configure({"provider": "ollama", "endpoint": endpoint, "model": "mock-model"}), "Ollama 配置通过")
	server.queue_json(200, {"message": {"content": JSON.stringify({"summary": "玩家反复翻滚后攻击，证据有限。", "directive": {"roll_response": "evade", "aggression": 0.6}})}})
	_check(bridge.request_summary({"world_model": {"confidence": 0.6, "patterns": {"roll_count": 3}}}), "Ollama 异步请求已启动")
	_check(bridge.busy, "请求启动后 busy")
	_check(not bridge.request_summary({}), "busy 时拒绝并发请求")
	await _wait_until_idle(bridge)
	_check(not bridge.busy and last_summary.begins_with("玩家反复"), "Ollama 返回摘要并结束 busy")
	_check(str(last_directive.get("roll_response", "")) == "evade", "Ollama directive 通过白名单解析")
	_check(server.received_bodies.size() == 1, "mock 收到真实 HTTP 请求")
	_check(server.received_paths[0] == "/api/chat", "Ollama 使用 native /api/chat 路径")
	var sent := JSON.parse_string(server.received_bodies[0]) as Dictionary
	_check(str(sent.get("model", "")) == "mock-model" and sent.get("messages") is Array, "请求包含模型与消息")
	_check(str(sent["messages"][1].get("content", "")).contains("confidence"), "只发送调用方提供的 context")

	var compatible_config := {"provider": "openai_compatible", "endpoint": "http://127.0.0.1:%d/v1" % server.port, "model": "mock-openai"}
	_check(bridge.configure(compatible_config), "OpenAI-compatible 配置通过")
	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "保持观察。", "directive": {"name": "observe_and_probe", "exploration_rate": 0.2}})}}]})
	_check(bridge.request_summary({"world_model": {"actions_seen": 1}}), "OpenAI-compatible 异步请求已启动")
	await _wait_until_idle(bridge)
	_check(last_summary == "保持观察。" and str(last_directive.get("name", "")) == "observe_and_probe", "OpenAI-compatible 响应解析")
	_check(server.received_paths[-1] == "/v1/chat/completions", "兼容服务使用 /chat/completions 路径")
	var compatible_sent := JSON.parse_string(server.received_bodies[-1]) as Dictionary
	_check(compatible_sent.get("response_format", {}).get("type", "") == "json_object" and compatible_sent.get("stream") == false, "兼容服务请求非流式 JSON 输出")
	if FileAccess.file_exists("res://key.txt"):
		var key_config := compatible_config.duplicate()
		key_config["key_file"] = "res://key.txt"
		key_config["response_format"] = false
		_check(bridge.configure(key_config), "key_file 配置通过")
		server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "密钥路径请求。", "directive": {}})}}]})
		_check(bridge.request_summary({"world_model": {"key_file": true}}), "key_file 请求已启动")
		await _wait_until_idle(bridge)
		var wire_headers := str(server.received_headers[-1])
		_check(wire_headers.contains("Authorization: Bearer sk-evomap-") and not wire_headers.contains("sk-evomap-sk-evomap-"), "key_file 直接使用完整 Bearer token")
		var key_sent := JSON.parse_string(server.received_bodies[-1]) as Dictionary
		_check(not key_sent.has("response_format"), "EvoMap 兼容请求可省略 response_format")

	var successes_before_failure := received_summaries
	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "非法输出。", "directive": {"roll_response": "deal_infinite_damage"}})}}]})
	_check(bridge.request_summary({"world_model": {}}), "非法输出请求仍异步启动")
	await _wait_until_idle(bridge)
	_check(not bridge.busy and last_error.contains("允许列表") and received_summaries == successes_before_failure, "非法 directive 被拒绝且不发 summary")
	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "不能改变伤害。", "directive": {"damage": 9999}})}}]})
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("未授权字段") and received_summaries == successes_before_failure, "拒绝伤害等未授权字段")
	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "越界策略。", "directive": {"aggression": 4.0}})}}]})
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("允许范围") and received_summaries == successes_before_failure, "拒绝越界策略数值")
	server.queue_text(200, "not JSON")
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("不是 JSON") and received_summaries == successes_before_failure, "拒绝错误 HTTP JSON")
	server.queue_json(200, {"choices": [{"message": {"content": "```json\n{}\n```"}}]})
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("纯 JSON") and received_summaries == successes_before_failure, "拒绝非纯 JSON 模型文本")
	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "x".repeat(1201), "directive": {}})}}]})
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("长度限制") and received_summaries == successes_before_failure, "拒绝过长摘要")

	server.queue_json(503, {"error": "mock failure"})
	_check(bridge.request_summary({"world_model": {}}), "HTTP 失败请求启动")
	await _wait_until_idle(bridge)
	_check(not bridge.busy and last_error.contains("HTTP 503"), "HTTP 错误进入 request_failed")
	var small_body_config := compatible_config.duplicate()
	small_body_config["max_response_bytes"] = 1024
	_check(bridge.configure(small_body_config), "响应体限制可配置")
	server.queue_text(200, "x".repeat(2048))
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("大小限制") and received_summaries == successes_before_failure, "响应体大小在传输阶段受限制")
	var short_timeout_config := compatible_config.duplicate()
	short_timeout_config["timeout_seconds"] = 0.1
	_check(bridge.configure(short_timeout_config), "超时配置通过")
	server.responses.append({"silent": true})
	bridge.request_summary({})
	await _wait_until_idle(bridge)
	_check(last_error.contains("超时") and not bridge.busy, "不响应的 HTTP 服务触发超时")
	_check(bridge.configure(compatible_config), "取消测试配置恢复")

	server.queue_json(200, {"choices": [{"message": {"content": JSON.stringify({"summary": "将被取消。", "directive": {}})}}]})
	_check(bridge.request_summary({"world_model": {"x": 1}}), "取消测试请求启动")
	bridge.cancel_request()
	_check(not bridge.busy, "cancel_request 清理 busy")
	await _wait_frames(4)
	_check(received_summaries == successes_before_failure, "取消旧会话后不会应用旧模型响应")
	_check(not bridge.request_summary({"not_json": Vector3.ONE}), "拒绝非 JSON context")
	_check(not bridge.request_summary({"oversized": "x".repeat(65536)}), "限制世界模型请求大小")
	var missing_key_config := compatible_config.duplicate()
	missing_key_config["api_key_env"] = "ADAPTIVE_BOSS_LLM_BRIDGE_UNSET_TEST_%d" % Time.get_ticks_usec()
	_check(bridge.configure(missing_key_config) and not bridge.request_summary({}), "缺少指定密钥环境变量时不发送请求")
	_check(not bridge.configure({"provider": "ollama", "endpoint": endpoint, "model": "mock", "enabled": false}) and not bridge.is_configured(), "显式禁用后不视为已配置")
	_check(not bridge.configure({"provider": "unknown", "endpoint": endpoint, "model": "mock"}), "拒绝不支持的 provider")
	_check(not bridge.configure({"provider": "ollama", "endpoint": endpoint, "model": "mock", "api_key": ""}), "配置不接受直接保存密钥")
	_print_result()
	server.stop()
	quit(0 if failed == 0 else 1)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await process_frame


func _wait_until_idle(bridge: Node) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while bridge.busy and Time.get_ticks_msec() < deadline:
		await process_frame
	if bridge.busy:
		_check(false, "mock 请求应在三秒内完成")
		bridge.cancel_request()


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)


func _print_result() -> void:
	print("LLM BRIDGE RESULT: %d passed, %d failed" % [passed, failed])
