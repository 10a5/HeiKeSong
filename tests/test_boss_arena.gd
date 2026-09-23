extends SceneTree
## The migrated mirror fights the live player on the imported duel floor.
## Use a distant origin to catch any remaining world-origin assumptions.

var passed := 0
var failed := 0
var stage: Node3D
var arena: Variant
var player: Variant
var boss: Variant
var actions: Array[String] = []
var finishes: Array[StringName] = []
var hits: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	stage = Node3D.new()
	root.add_child(stage)
	arena = load("res://boss_arena.gd").new()
	arena.position = Vector3(1000.0, 0.0, 2000.0)
	stage.add_child(arena)
	await _frames(3)
	_check(arena.arena.scene_file_path == "res://model/决战场景.glb", "决战场使用主项目现有 GLB")
	_check(arena.arena.scale.is_equal_approx(Vector3.ONE * 0.6), "决战场整体放大一倍")
	_check(arena.arena_rect == Rect2(-19.0, -15.0, 38.0, 30.0), "放大后的场地边界同步覆盖双倍活动范围")
	_check(is_equal_approx(arena.arena.rotation_degrees.x, -15.0) and is_equal_approx(arena.arena.position.y, -5.0), "决战场保持实验场地面旋转与高度")
	_check(not arena.arena.find_children("*", "StaticBody3D", true, false).is_empty(), "导入模型生成真实三角网格碰撞")
	var spawn: Vector3 = arena.player_spawn()
	_check(absf(spawn.x - 1000.0) < 0.01 and absf(spawn.z - 2008.0) < 0.01, "玩家出生点跟随放大后的场地全局偏移")
	_check(spawn.y > -5.0 and spawn.y < 5.0, "玩家出生点射线命中真实地面")
	player = load("res://player.gd").new()
	player.name = "Player"
	player.spawn_position = spawn
	player.arena_rect = arena.world_bounds()
	player.max_health = 10000.0
	stage.add_child(player)
	player.collision_mask |= 4
	boss = arena.spawn_boss(player)
	boss.action_played.connect(func(kind: String, _cost: float): actions.append(kind))
	boss.combo_finished.connect(func(kind: StringName): finishes.append(kind))
	boss.attack_observed.connect(func(kind: String, hit: bool, damage: float): hits.append({"kind": kind, "hit": hit, "damage": damage}))
	_check(arena.spawn_boss(player) == boss, "重复请求出生不会生成第二个 Boss")
	_check(not player.bounds_enabled and not boss.bounds_enabled and boss.arena_rect == arena.world_bounds(), "Boss 战关闭矩形空气墙并保留边界数据供导航")
	_check(boss.arena_rect.has_point(Vector2(boss.global_position.x, boss.global_position.z)), "Boss 出生点位于偏移后的边界中")
	var water_surface := arena.get_node_or_null("BossShallowWater/BossWaterSurface") as MeshInstance3D
	_check(water_surface != null, "Boss 战生成浅水视觉表面")
	_check(water_surface != null and water_surface.material_override is ShaderMaterial and (water_surface.material_override as ShaderMaterial).shader.resource_path == "res://materials/boss_water.gdshader", "Boss 浅水使用动态波纹材质")
	_check(arena.get_node_or_null("BossShallowWater").find_children("*", "StaticBody3D", true, false).is_empty(), "Boss 浅水层不创建空气墙或地面碰撞")
	_check(boss._character_visual.model_root.scene_file_path == player._character_visual.model_root.scene_file_path, "Boss 使用当前主角 GLB")
	_check(boss._character_visual.skeleton != player._character_visual.skeleton, "Boss 和玩家拥有独立骨骼")
	await _test_entrance()
	await _test_roll_combo()
	await _test_dash_kick_combo()
	await _test_delayed_kick_and_cancel()
	await _test_shield_and_bounds()
	stage.queue_free()
	await process_frame
	print("BOSS ARENA RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_entrance() -> void:
	_check(boss.is_entering and is_equal_approx(boss.entrance_duration, 3.0), "Boss 出生开启完整 3 秒入场")
	_check(boss.get_node("EntranceShell").visible and boss.get_node("EntranceScanRing").visible, "入场无敌盾和扫描环可见")
	var health_before: float = boss.health
	_check(not boss.take_damage(100000.0, true) and is_equal_approx(boss.health, health_before), "入场无敌兼容新版伤害接口并阻止伤害")
	_check(not boss.request_card("slash"), "入场期间无法提前出牌")
	await _frames(120)
	_check(boss.is_entering and actions.is_empty(), "入场两秒仍未攻击")
	_check(boss.is_on_floor() and player.is_on_floor(), "偏移场地中双方稳定接地")
	var boss_y: float = boss.global_position.y
	var player_y: float = player.global_position.y
	await _frames(30)
	_check(absf(boss.global_position.y - boss_y) < 0.04 and absf(player.global_position.y - player_y) < 0.04, "站立不会穿过场地无限下落")
	boss.combat_enabled = false
	await _frames(35)
	_check(not boss.is_entering and not boss.get_node("EntranceShell").visible, "入场结束后护盾淡出")
	_check(actions.is_empty() and boss.state == &"idle", "禁用战斗时入场结束仍安静等待")
	_check(boss.take_damage(7.0) and is_equal_approx(boss.health, health_before - 7.0), "入场结束恢复普通受伤")


func _test_roll_combo() -> void:
	await _reset_fixture()
	boss.planned_combo = &"roll_punches"
	boss.energy = 9.9
	boss.combat_enabled = true
	await _frames(35)
	_check(actions.is_empty(), "不足整套费用不会启动翻滚双拳")
	boss.energy = 10.0
	await _wait_for_finish(240)
	_check(actions == ["roll", "slash", "slash", "roll"], "依次执行前滚、出拳、出拳、后滚")
	_check(finishes == [&"roll_punches"], "翻滚双拳完整结束")
	_check(is_zero_approx(boss.energy), "翻滚双拳只消耗预留的 10 点能量")
	_check(player.health < player.max_health and hits.size() == 2, "两次拳击真实命中玩家")
	_check(is_equal_approx(boss.health, boss.max_health), "Boss 不会把自己当作命中目标")
	_check(boss.is_on_floor() and boss.global_position.y > arena.global_position.y - 4.0, "翻滚与后撤后仍站在模型地面")


func _test_dash_kick_combo() -> void:
	await _reset_fixture()
	boss.planned_combo = &"dash_kick"
	boss.energy = 7.0
	boss.combat_enabled = true
	await _wait_for_finish(240)
	_check(actions == ["dash_slash", "front_kick"] and finishes == [&"dash_kick"], "依次执行突进出拳和回旋踢")
	_check(is_zero_approx(boss.energy), "突进回旋踢只消耗 7 点能量")
	var dash_hits := 0
	var kick_hits := 0
	for hit in hits:
		if hit["kind"] == "dash_slash":
			dash_hits += 1
		elif hit["kind"] == "front_kick":
			kick_hits += 1
	_check(dash_hits == 1, "突进路径与终点挥拳不会重复伤害")
	_check(kick_hits == 1, "新版延迟回旋踢真实命中一次")
	_check(is_equal_approx(player.health, player.max_health - boss.dash_slash_damage - boss.front_kick_damage), "第二套连招总伤害对应两次攻击")
	_check(not boss._is_front_kick_active() and boss.front_kick_damage_fired, "连招结束会等待回旋踢完整动作锁")


func _test_delayed_kick_and_cancel() -> void:
	await _reset_fixture()
	player.global_position = arena.surface_point(0.0, 0.8)
	boss.energy = 10.0
	boss.combat_enabled = true
	boss.move_speed = 0.0
	boss._recovery_left = 10.0
	boss.shield_cooldown_left = 10.0
	var health_before: float = player.health
	_check(boss.request_card("front_kick"), "Boss 可以使用主游戏回旋踢")
	await _frames(30)
	_check(is_equal_approx(player.health, health_before) and boss._is_front_kick_active(), "前半秒回旋踢尚未命中且仍被动作锁约束")
	boss.combat_enabled = false
	await _frames(45)
	_check(is_equal_approx(player.health, health_before), "停止战斗后不遗留回旋踢延迟伤害")
	_check(not boss._is_front_kick_active() and is_zero_approx(boss.front_kick_damage_delay_left), "取消连招清除新版回旋踢计时器")


func _test_shield_and_bounds() -> void:
	await _reset_fixture()
	# The boss now starts at z=-1.0; keep the player within the 1.7m
	# proximity trigger after the arena footprint doubles.
	player.global_position = arena.surface_point(0.0, -0.2)
	boss.move_speed = 0.0
	boss.energy = 4.0
	boss.combat_enabled = true
	await _frames(5)
	_check(actions == ["shield"] and is_equal_approx(boss.energy, 2.0), "玩家近身触发费用 2 的护盾")
	_check(is_equal_approx(boss.shield, 10.0), "近身护盾提供 10 点护盾")
	boss.take_damage(7.0)
	_check(is_equal_approx(boss.shield, 3.0) and is_equal_approx(boss.health, boss.max_health), "普通护盾真实吸收伤害")
	boss.combat_enabled = false
	var outside: Vector2 = arena.world_bounds().end + Vector2(2.0, 2.0)
	boss.global_position.x = outside.x
	boss.global_position.z = outside.y
	boss._clamp_to_arena()
	_check(is_equal_approx(boss.global_position.x, outside.x) and is_equal_approx(boss.global_position.z, outside.y), "Boss 越过旧矩形范围时不会被空气墙拉回")


func _reset_fixture() -> void:
	boss.combat_enabled = false
	boss.entrance_duration = 0.0
	boss.energy_regen_per_second = 0.0
	boss.move_speed = 3.2
	boss.reset_enemy()
	player.reset_player()
	await _frames(12)
	player.set_physics_process(false)
	actions.clear()
	finishes.clear()
	hits.clear()


func _wait_for_finish(max_frames: int) -> void:
	for _index in range(max_frames):
		await physics_frame
		if not finishes.is_empty():
			return


func _frames(count: int) -> void:
	for _index in range(count):
		await physics_frame


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
