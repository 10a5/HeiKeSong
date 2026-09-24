# 新手教学关 · 交付包

这个包里是《神经断层》新手引导教学关（“神经校准”）的全部内容，可以直接放进 Godot 项目使用。

## 包内容

| 文件 | 说明 |
| --- | --- |
| `tutorial.gd` | 教学关全部逻辑：步骤机、提示 HUD、手牌控制、战斗节奏、场景跳转 |
| `tutorial.tscn` | 教学关场景文件 |
| `新手引导教学关说明.md` | 完整设计文档：教学目标、五个步骤、参数速查、自测清单、移植说明 |

## 三步接入

1. **复制文件**：把 `tutorial.gd`、`tutorial.tscn` 放到项目根目录（和 `main.gd`、`player.gd` 同级）。
2. **设为启动场景**：在 `project.godot` 中修改

   ```ini
   [application]
   run/main_scene="res://tutorial.tscn"
   ```

3. **改跳转目标**（可选）：如果你们的主关卡不是 `res://floor_one.tscn`，改 `tutorial.gd` 里的
   `_skip_to_first_floor()`。

## 依赖

教学关通过 `extends "res://main.gd"` 继承主场景，需要项目里已有：

- `main.gd`：提供 `player`、`deck`、`enemy`、`hud`、`unlock_terminals`，以及 `_box()`、`_ring()` 等建模辅助方法
- `player.gd`：需要 `action_played`、`status_changed` 信号，以及 `energy`、`max_energy`、`reset_player()`
- `deck.gd`：需要 `hand`、`draw_pile`、`discard_pile`、`refill_time_left`、`refill_delay`、`piles_changed`
- `enemy.gd`：需要 `spawn_position`、`max_health`、`attack_damage`、`combat_enabled`、`is_dead`、`reset_enemy()`

移植到其他项目时，最小的必要接口就是上面这四类对象。

## 教学流程一句话版

移动 → 跳跃 → 出牌 → 只用一张【翻滚】躲开敌人第一刀 → 手牌换成攻击牌完成击杀 → 进入第一层。
战斗教学里敌人有 **3 秒缓冲**才出手，给玩家读提示的时间。

## 快速验证

打开 `tutorial.tscn` 按 F6 单跑；或按 F5 走完整启动流程。
检测清单见《新手引导教学关说明.md》第 10 节。
