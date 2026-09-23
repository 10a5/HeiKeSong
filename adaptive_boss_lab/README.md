# Adaptive Boss Behavior Lab

这是一个与主游戏隔离的 Godot 实验项目，用来验证：

**玩家事件 → 世界模型画像 → 策略判断 → 低延迟 FSM 反应 → Boss 接收器**

项目不依赖网络或外部 LLM。`strategy_adapter.gd` 是一个确定性的本地策略占位器，用来模拟“LLM 读摘要后返回有限 JSON”的步骤；真正接入 LLM 时只需替换这个适配器。`boss_brain.gd` 的 `get_llm_context()` 是输入边界，实时反应始终由本地 FSM 完成，LLM 不参与命中、伤害、抽牌或胜负。

## 启动

```sh
/Applications/Godot.app/Contents/MacOS/Godot --editor --path adaptive_boss_lab
```

点击运行场景后可使用：

- `1` 或按钮：播放“翻滚 → 劈砍”的重复习惯，达到 3 次证据后，玩家下一次翻滚会让 FSM 输出 `evade`，并显示 `punish_after: roll_recovery`。
- `2`：播放射击、闪现和多种复合动作，观察策略层选择 `keep_distance`。
- `3`：播放能量不足和失败尝试，观察 `attempts.rejected` 与拒绝率。
- `Space`：播放目标习惯，`R`：清空画像。

界面三列分别展示事件流、世界模型和策略/FSM。底部置信度条表示当前证据量。

`replays/*.json` 就是可替换的行为日志输入。事件中的 `energy` 表示动作消耗前的能量；模拟玩家扣费后再发送 `action_played`，因此世界模型可以正确计算能量投入区间。为了让回放可重复，当前实验只展示并约束 `exploration_rate`，没有开启随机探索。

动作画像保留最近 40 个动作，并按半衰期衰减连招证据；受伤、闪避成功和动作结果事件在这个原型中仍是会话累计计数，后续可再加入独立事件窗口。

## 自动验证

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path adaptive_boss_lab --fixed-fps 60 --script tests/test_pipeline.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path adaptive_boss_lab --fixed-fps 60 --script tests/test_lab_scene.gd
```

前一个测试不加载主游戏场景，验证动作计数、连招识别、能量门槛、失败尝试、摘要边界、策略白名单和 reaction signal。后一个测试加载独立场景，从 JSON 回放目录播放完整链路，确认低频策略更新后 `evade` 确实抵达 Boss 接收器。
