# sniper_rifle — 狙击手 + 步枪装配包

把 `狙击手.glb`（带 4 段动画的 Mixamo 骨骼角色）和 `futuristic gun 3d model.glb`
装在一起，做成**可直接拷贝使用**的一个文件夹。

---

## 1. 怎么用（队友看这里）

1. 把整个 `sniper_rifle/` 文件夹拷到你 Godot 4 项目的**根目录**（和 `project.godot` 同级）。
2. 打开项目，Godot 会自动导入 `assets/` 里的两个 `.glb`。
3. 二选一：
   - **直接用**：把 `sniper_rifle.tscn` 拖进你的关卡（instance）。
   - **先看效果**：把 `sniper_showcase.tscn` 设为主场景或直接 F6 运行，
     它会自动轮流播放 4 段动画。`N` 下一个 / `R` 重播 / `Space` 暂停。

> 路径是 `res://sniper_rifle/...`，所以**必须放在项目根目录**，改名字或换层级都会断引用。
> 两个 `.glb` 的贴图是内嵌的，文件夹拷走就是完整的，不依赖本项目其它文件。

```gdscript
# 代码里取枪口位置（做射线、特效挂点都够用）
var rifle := $SniperRifle/WeaponMount
var muzzle_world: Vector3 = rifle.muzzle_hint(Vector3(-47.85, 10.10, 22.45))
```

## 2. 里面有什么

| 文件 | 说明 |
|---|---|
| `sniper_rifle.tscn` | **装配好的角色**：狙击手 + 步枪，直接可用 |
| `sniper_showcase.tscn` | 演示场景：自动轮播全部动画，相机跟随髋骨 |
| `weapon_hand_mount.gd` | 把武器锁在任意角色手骨上的通用脚本（`@tool`，编辑器里也能看到枪在手上） |
| `sniper_showcase.gd` | 演示场景的播放/相机逻辑 |
| `assets/sniper.glb` | 狙击手，65 骨骼，4 段动画，贴图内嵌 |
| `assets/rifle.glb` | 未来步枪，静态网格（无骨骼），贴图内嵌 |

整个文件夹约 67 MB：两个 `.glb` 本身 36 MB（贴图已内嵌），Godot 首次导入时会把内嵌贴图
解包成同目录的 `.jpg/.png`（31 MB），所以不要手动删那些贴图，它们和 `.import` 是一对。

> 想瘦身：把两个 `.glb.import` 里的 `gltf/embedded_image_handling=1` 改成 `2`
> （以 BasisU 内嵌、不落地），删掉解包出来的贴图和它们的 `.import`，重新导入即可回到 36 MB。
> 代价是首次导入变慢。

## 3. 动画

| clip | 时长 | 内容 |
|---|---|---|
| `shoot_001` | 9.08 s | 完整狙击流程：走位 → 卧倒/蹲姿 → 瞄准 |
| `fire_001` | 1.54 s | 站姿射击 |
| `hit_to_head_001` | 1.88 s | 头部受击 |
| `defeat_03_001` | 5.58 s | 倒地阵亡 |

> ⚠️ **`shoot_001` 带 root motion**：这段动画自己会把角色往前推约 2.6 m 并压低到卧姿。
> 如果你的控制器也在移动角色，两者会打架。要么用 `AnimationMixer` 的 root motion 提取，
> 要么播放前把角色的 transform 每帧写回去。`sniper_showcase.gd` 里的跟随相机就是为了
> 不让角色走出画面才那么写的。

## 4. 枪是怎么装上去的

角色资产里**没有枪的插槽**，只有手骨。`WeaponMount` 每帧把自身 transform 从
`mixamorig_RightHand` 推出来，所以**任何动画都不需要一条枪的轨道**——换枪、换手、
挂到别的角色，都是改场景而不是重新导出。

`mount` 这个 `Transform3D` 是"枪在手骨空间里的位姿"，已解算好写进场景。枪自身的缩放
（`0.00669371`）放在 `Rifle` 子节点上，所以 `mount` 在 Inspector 里是一个纯朝向，好调。

### 解算依据

枪的握把坐标系是从它**自己的顶点**量出来的（枪身沿自身 XZ 平面斜置、单位是厘米），
见 `modeling/tools/gun_hold_fit.py`。握把点和枪口位置：

```
尾握把 (t=+11cm, 口线下 6cm)  →  掌心
前托手 (t=-18cm, 口线下 6cm)  →  左手
枪口   (t=-52.65cm)
```

朝向不是拍脑袋定的：**用动画本身当标定**。右手是后握把、左手托前托，所以
"左手 − 右手"就是枪管方向，两手间距决定枪该多长。`mount` 是在两段瞄准动画
（`shoot_001` + `fire_001`）上做最小二乘拟合出来的，不是只在某一帧上对一次。

## 5. 已知限制（重要，别当成 bug）

- **两段瞄准动画的两手间距不一致**：`shoot_001` 是 0.217 m，`fire_001` 是 0.171 m。
  刚体枪只能选一个折中，因此在前托手处留下残差：

  | clip | 前托手偏差 | 枪管对准度 |
  |---|---|---|
  | `shoot_001` | 6.1 cm | 0.99 |
  | `fire_001` | 10.2 cm | 0.99 |

  握把端是精确的（偏差 4.6 cm 就是"掌心偏移"本身，不是误差）。
  想让某一段更准，改 `tests/test_sniper_grip_solve.gd` 里的采样或权重重跑即可。
- **`hit_to_head_001` / `defeat_03_001` 里手会离开枪**（受击、倒地时本来就该松手），
  这不是装配问题。
- **角色原生身高 0.977 m**，场景根节点用 `scale = 1.8424` 拉到约 1.80 m。
  缩放根节点会等比缩放枪，所以两者始终协调；想保持原生尺寸把 scale 改回 1。
- 模型来自第三方（Tripo / 素材站），**商用前请自行确认授权**。

## 6. 改的时候注意

- 枪跟不跟手由 `WeaponMount.follow` 控制，关掉就可以自己做入套/换弹动画。
- 换枪：改 `WeaponMount/Rifle` 的 instance，然后按第 4 节重新解一次 `mount`。
- 换角色：把 `WeaponMount.character_path` 指向新角色，`hand_bone` 改成它的手骨名
  （Godot 会把 Mixamo 的 `mixamorig:` 导成 `mixamorig_`）。

## 7. 回归测试

```bash
# 在 Godot 编辑器里跑（本项目的 godot_ai 插件的测试面板），或：
python -m modeling.tools.gun_hold_fit      # 重新量枪的握把坐标系
```

- `tests/test_sniper_rifle.gd` — 加载本场景，逐帧检查枪是否还在两只手上（防回归）
- `tests/test_sniper_grip_solve.gd` — 重新拟合 `mount` 和枪的缩放

这两个测试在当前项目里，**拷给队友时不需要带走**，除非他们也要自己重解。
