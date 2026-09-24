#!/bin/bash
# Launch the project with an existing Godot 4.3+ installation.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

show_error() {
    printf '\n%s\n' "$1" >&2
    if [[ -t 0 ]]; then
        printf '\n按回车关闭此窗口。\n' >&2
        read -r _answer
    fi
    exit 1
}

if [[ ! -f "$script_dir/project.godot" ]]; then
    show_error "没有找到 project.godot。请将本脚本放在完整 Demo 项目文件夹中运行。"
fi

candidates=()
for command_name in godot godot4; do
    candidate="$(command -v "$command_name" 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        candidates+=("$candidate")
    fi
done
candidates+=("/Applications/Godot.app/Contents/MacOS/Godot")
candidates+=("$HOME/Applications/Godot.app/Contents/MacOS/Godot")

godot_bin=""
godot_version=""
for candidate in "${candidates[@]}"; do
    if [[ ! -x "$candidate" ]]; then
        continue
    fi
    version_output="$("$candidate" --version 2>/dev/null)" || continue
    if [[ "$version_output" =~ ^4\.([0-9]+)\. ]]; then
        minor_version="${BASH_REMATCH[1]}"
        if (( minor_version >= 3 )); then
            godot_bin="$candidate"
            godot_version="$version_output"
            break
        fi
    fi
done

if [[ -z "$godot_bin" ]]; then
    show_error "未找到可运行的 Godot 4.3 或更新的 4.x 版本。
请先安装并打开 Godot 4.x，然后将 Godot.app 放入 /Applications，
或让 PATH 中的 godot / godot4 命令指向兼容版本。
也可在 Godot 项目管理器中导入本目录的 project.godot，按 F5 运行。
本启动脚本不会下载或安装软件。"
fi

printf '使用 Godot %s\n项目：%s\n\n' "$godot_version" "$script_dir"
if ! "$godot_bin" --headless --editor --path "$script_dir" --import --quit; then
    show_error "项目资源导入失败。请在 Godot 编辑器中打开 project.godot 查看错误。"
fi
"$godot_bin" --path "$script_dir"
exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    show_error "Godot 退出，状态码为 $exit_code。请查看上方错误信息，或在 Godot 编辑器中导入 project.godot 后按 F5 运行。"
fi
