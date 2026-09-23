# 绿色数字雨转场

打开 `matrix_transition_preview.tscn`，按 F6 预览。每轮保持 5 秒，空格重播，Esc 退出。主游戏中按 T 播放一次短转场；这个快捷键只预览画面，不切换地图或暂停战斗。

组件为 `matrix_transition.gd`，已作为训练场和第一层 HUD 的子节点加载，默认隐藏。黑底上有两层不同大小和速度的绿色数字流，带随机闪动、渐隐拖尾、头部微光和扫描线。隐藏时停止帧更新，不需要视频或图片素材，支持 Compatibility 渲染器。

## 调用

完整播放（参数依次为淡入、保持、淡出秒数）：

```gdscript
hud.play_matrix_transition(0.24, 0.85, 0.34)
await hud.matrix_transition.finished
```

需要在遮罩后执行操作时，分开控制淡入和淡出。例如在第一层脚本中：

```gdscript
var effect = hud.matrix_transition
effect.play_in(0.3)
await effect.covered
regenerate_floor() # HUD 保留，数字雨继续遮住地图
effect.play_out(0.4)
await effect.finished
```

`play_in()` 完成后持续保持，直到 `play_out()` 或 `stop()`。`covered` 表示淡入完成，`finished` 表示淡出完成；`stop()` 立即隐藏，不发出完成信号。再次调用播放方法会重启当前效果。组件在暂停时仍播放，鼠标穿透；需要冻结游戏或阻止出牌时，由调用方控制。

使用 `change_scene_to_file()` 更换整个场景时，HUD 会随旧场景释放。届时应把组件挂在 Autoload 的 CanvasLayer 下，让转场层跨场景保留，再在新场景准备好后淡出。当前组件也可以直接实例化为任意 CanvasLayer 的子节点。

## 调节外观

独立预览脚本的导出属性可设置三个阶段与循环间隔时长。特效脚本的导出属性可调整数字字号、列间距、下落速度、拖尾亮度、背景透明度、扫描线强度和轻微抖动。默认背景完全遮住下层画面。
