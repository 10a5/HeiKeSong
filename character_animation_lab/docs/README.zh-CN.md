# Character Animation Lab

这是一个独立的 Godot 4 项目，用来手动调整角色骨骼、制作关键帧动画，并把动画资源导出给主游戏。它和上层 `hks` 游戏互不依赖，打开 `character_animation_lab/project.godot` 即可单独运行。

## Godot 原生编辑流程

Godot 自带 `Skeleton3D` 骨骼 gizmo 和 `AnimationPlayer` 动画时间轴，可以直接完成第一版动作编辑：

1. 用 Godot 导入本目录的 `project.godot`，打开 `main.tscn`。
2. 在场景树展开 `CharacterPivot/CharacterRig/Character/Armature/Skeleton3D`，选中 `Skeleton3D`。`CharacterRig.tscn` 已开启 Editable Children，可以直接进入骨骼编辑模式。
3. 在 3D 视图中选骨骼并拖动旋转 gizmo。需要回到模型原姿态时，在 Skeleton3D 的骨骼菜单使用 **Reset Pose**。
4. 选中 `CharacterPivot/CharacterRig/AnimationPlayer`，在底部 Animation 面板新建动画，例如 `slash`、`roll`、`dash_slash`。
5. 把时间轴移动到需要的时间点，选中 `Skeleton3D`，为要记录的骨骼属性点击钥匙按钮插入关键帧。建议先做 0 秒准备、0.12 秒命中、0.32 秒收势三个关键姿态，再逐步加细节。
6. 点击 AnimationPlayer 的保存按钮，场景会保存动画库。动画也可以从 Animation 面板菜单 **Save As...** 单独保存成 `exports/*.tres`。
7. 在主项目中把 `.tres` 拖入 AnimationPlayer 的 AnimationLibrary，或把 FBX 角色场景替换为这个项目制作的角色场景。

> 目前模型只有骨架和蒙皮，没有自带可编辑动画片段；这是预期行为。所有动作都由本项目中的 AnimationPlayer 关键帧记录。

## 资源引用策略

- 角色源文件位于 `assets/tactical_female_armor/`，包含 FBX 和同名 `.fbm` 贴图目录。首次打开项目时 Godot 会在本项目自己的 `.godot/imported` 中重新导入，不依赖上层项目的导入缓存。
- 更新角色时，替换整个 `assets/tactical_female_armor/` 目录并保持 FBX 文件名，Godot 会重新导入；如果模型文件名改变，同时更新 `main.tscn` 的 `ExtResource` 路径。
- 动画成品建议保存到 `exports/`，以 `.tres` 形式提交。`.godot/` 是编辑器缓存，不要复制到主项目。
- 主游戏使用同一套骨骼命名（Mixamo `mixamorig_*`）。导出动画时不要重命名骨骼，否则主游戏的动作映射需要同步修改。

## 导出到主游戏

推荐导出两种方式：

1. **AnimationLibrary `.tres`**：在 AnimationPlayer 的动画面板使用 **Save As...**，将动作保存到 `exports/slash.tres` 等文件，然后复制到主项目并加载到主场景的 AnimationPlayer。
2. **带动画的 glTF/GLB**：如果要给其他工具使用，可在 Godot 或 Blender 中导出带骨骼动画的 glTF/GLB；导出前确认模型使用同一套骨骼层级和单位（人物约 1.8 米）。

第一次动作制作建议只做 `idle`、`walk`、`slash` 三个动作，验证导入主游戏后再扩展翻滚和冲刺挥砍。

## 导出目录

动作资源请保存到 `exports/`。
