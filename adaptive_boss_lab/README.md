# 玩家行为分析实验场

与主游戏隔离的 Godot 项目，用真实角色和卡牌操作验证「玩家操作 → 行为摘要 → 策略判断 → 本地反应意图」的路径。默认离线运行，先导出 JSON，之后再配置 LLM。

## 启动与操作

用 Godot 打开本目录的 `project.godot`，等待首次资源导入完成，按 **F5**。默认运行 `battle_scene.tscn`。也可以在仓库根目录执行：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --editor --path adaptive_boss_lab
```

场景使用 `决战场景.glb`，根据模型实际表面生成静态网格碰撞，并通过射线确定出生点。角色可以在竞技场内移动、跳跃和交战。项目限帧 60 FPS。

| 操作 | 输入 |
| --- | --- |
| 移动 | WASD / 方向键 |
| 跳跃 | Space |
| 打出手牌 | 1–4 / 点击卡牌 |
| 爆发加速义体 | Q |
| 旋转视角 | 按住鼠标左键拖动 |
| 缩放 | 滚轮 / 触控板捏合、双指滑动 |
| 查看完整牌组 | Tab /「查看卡组」|
| 查看对应牌堆 | 点击左右两侧的抽牌堆、弃牌堆 |
| 查看行为总结 | B / 顶部「行为总结 / LLM」|
| 暂停 / 继续 | Esc |
| 重置角色、牌组及观察记录 | R /「新观察」|

玩家模型、跑步/待机动画、平滑转向、跳跃、义体、护盾和连招沿用当前主游戏的资源与机制。实验场预先解锁 **13 种动作、18 张实体牌**，每次持有四张手牌；出牌真实扣能量、进入弃牌堆，空槽一秒后随机补牌，抽牌堆耗尽后回收弃牌堆。

镜像训练对手有 500 点生命，仍使用原来的 0.3 秒抬手攻击。行为面板中可以关闭「训练对手主动攻击」以自由练习连招。查看行为面板或牌堆时暂停战斗，暂停时间不计入观察。

## 导出给 LLM 的 JSON

1. 进入场景，实际移动、出牌并与对手交战。
2. 按 **B** 查看当前行为总结。
3. 点击 **「导出 JSON」**，选择位置保存 `player_behavior.json`；顶部「导出总结」也可打开保存窗口。

导出内容包括常用动作、动作衔接（例如翻滚后接攻击）、能量投入、失败尝试、受伤与闪避事件，以及三维移动路程、腾空时间、与对手的距离、跳跃和实际攻击结果。`context.world_model.interpretation` 提供中文概述，`context` 可作为后续 LLM 的输入。

导出结构：

```text
schema / source             格式版本；来源为 live_player
context.world_model         动作与行为画像
context.world_model.gameplay 移动、跳跃、距离及真实攻击结果
context                     还包含当前策略、FSM 状态及统计边界
last_sent_context           最近一次成功发起模型请求的输入；离线时为空
llm_status / llm_summary     连接状态及模型回复；没有回复时明确标注
policy_source               local_rule 或 llm
```

统计范围有意区分：动作画像使用最近 **40 次成功出牌**，连招证据按时间衰减；`gameplay` 使用最近 **60 秒有效游玩时间**；脑模块中的总出牌数、失败尝试、事件和动作结果计数为本次会话累计。按 R 全部清空。攻击结果来自实际伤害/射线结算；没有近战命中事件不能直接推断为落空。

摘要不包含手牌、牌堆顺序、随机种子或 API 密钥。目前是统计画像与规则推断，尚未训练能预测因果结果的神经网络世界模型。界面的「证据评分」衡量样本量与时效，不是校准过的预测概率。

## 以后连接模型

当前未配置真实模型，自动发送默认关闭。`strategy_adapter.gd` 提供确定性的本地规则；界面会明确显示「本地规则」，不会把它当作模型回复。

以后可以编辑 `llm_config.example.json` 的副本，将 `enabled` 设为 `true`，填写服务地址与模型名，在行为面板点击「导入配置」。支持 Ollama 的 `/api/chat` 或 OpenAI 兼容的 `/chat/completions` 接口。需要认证时，`api_key_env` 只填写环境变量名，密钥由启动 Godot 的环境提供。

导入成功表示配置格式有效；收到真实有效响应后才显示模型回复。点击「发送给 LLM」（或 F6）发起一次异步请求；也可选择每 15 秒发送有新增出牌的摘要。保存的配置位于 Godot 的 `user://llm_config.json`，也支持项目本地的 `llm_config.local.json`（已被 Git 忽略）。

模型预期返回有限 JSON，例如：

```json
{
  "summary": "玩家多次在翻滚后衔接近身攻击，可在其能量充足时优先规避。",
  "directive": {"roll_response": "evade", "aggression": 0.5}
}
```

`llm_bridge.gd` 校验允许的策略字段，再交给 `boss_brain.gd` 的本地反应状态机。实时判定不等待网络，LLM 不直接决定命中、伤害、抽牌或胜负。当前对手接收并保存反应意图，**还没有把这些意图变成实际的自适应闪避/反击**；本次重点是验证真实操作采集与总结。`exploration_rate` 也只保留为参数，尚未启用随机探索。

## 保留的自动回放实验

旧版回放场景 `main.tscn` 仍可单独打开并按 F6 运行，或在仓库根目录执行：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path adaptive_boss_lab res://main.tscn
```

该场景中 1 / 2 / 3 分别播放翻滚接攻击、混合打法、能量不足的事件日志，Space 播放目标习惯，R 清空。`replays/*.json` 是可替换的回放输入。回放用于重复检查识别与策略路径，不代表真实玩家测试或真实 LLM 效果评估。

## 验证与项目边界

在仓库根目录运行下列命令，可将末尾脚本依次替换为表中的其他文件：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path adaptive_boss_lab --fixed-fps 60 --script tests/test_battle_scene.gd
```

| 测试文件 | 覆盖范围 |
| --- | --- |
| `tests/test_battle_scene.gd` | 实际场景碰撞、移动/跳跃/Q、出牌循环、伤害、暂停、JSON 导出与重置 |
| `tests/test_gameplay_observer.gd` | 三维移动累计、60 秒窗口、暂停排除、跳跃与攻击结果 |
| `tests/test_pipeline.gd` | 画像、连招证据、能量门槛、失败尝试、策略白名单与反应信号 |
| `tests/test_lab_scene.gd` | JSON 回放经策略层到 Boss 接收器的完整路径 |
| `tests/test_llm_bridge.gd` | 本机模拟 HTTP 服务、请求格式、响应校验、超时与取消；不调用真实 LLM |

本目录自带角色、场景、字体、动画和玩法脚本快照，可以独立导入 Godot。更新主游戏不会自动同步到实验场。实验场只在自己的玩家/敌人脚本中增加结果观察信号，不更改主游戏的战斗实现。`.godot/`、本地模型配置、`exports/` 和日志已加入本项目 `.gitignore`。
