# Noto Sans SC

本项目仅附带 `NotoSansSC-Regular.ttf`，为 Noto Sans SC 的静态常规字重（400），保留完整字符集，包含简体中文及 Latin 字符。

- 来源：[Google Fonts / Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc)
- 原始下载：[NotoSansSC[wght].ttf](https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf)
- 获取日期：2026-09-21
- 许可：SIL Open Font License 1.1，全文见同目录 `OFL.txt`。允许随本项目分发。
- 原始可变字体 SHA-256：`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`
- 项目内静态字体 SHA-256：`2e771728a4089d28b7a865ac4c757124e93b765ab534ea32545c0eb5fceb3384`

## 生成方式

使用 FontTools 将原始可变字体实例化为 `wght=400`，并同步更新名称表。没有子集裁切；授权仍为 SIL OFL 1.1。原始可变字体仅作为生成来源，不随项目附带。

```sh
fonttools varLib.instancer NotoSansSC-Variable.ttf wght=400 -o NotoSansSC-Regular.ttf --update-name-table
```

已使用 Godot 4.7.2 `FontFile.load_dynamic_font` 验证字体加载和当前项目脚本文本中的中文、ASCII 字符覆盖。
