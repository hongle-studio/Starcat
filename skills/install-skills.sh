#!/usr/bin/env bash
# Starcat skills 安装脚本
#
# 作用：把本仓库 skills/ 下的 skill 以「软链」方式安装到各 agent 工具的
#       用户级全局 skills 目录（如 ~/.codex/skills），不安装到项目内目录。
# 为什么用软链而不是拷贝：单一事实源在仓库里，git pull / 编辑后各工具立即生效，
#       不会出现多副本漂移；卸载也只需删链接。
#
# 用法：
#   ./install-skills.sh                      # 安装到默认目标：claude、codex、agents
#   ./install-skills.sh --all                # 追加 cursor、gemini、opencode
#   ./install-skills.sh --target claude,codex # 只安装到指定目标
#   ./install-skills.sh --list               # 只列出 skill 与目标，不做改动
#
# 安全约束：
#   - 目标位置已存在同名真目录 / 真文件时跳过并告警，绝不覆盖；
#   - 已是软链（含指向旧位置的悬空链）时原子替换为本仓库路径。
set -euo pipefail

SKILLS_ROOT="$(cd "$(dirname "$0")" && pwd)"

# 目标名 → agent 工具的用户级全局 skills 目录。
# 全部是各工具自己的发现路径，刻意不含任何项目内目录（如本仓库 .claude/skills）。
# bash 3.2（macOS 自带）没有关联数组，用 case 做映射。
target_dir() {
  case "$1" in
    claude)   echo "$HOME/.claude/skills" ;;
    codex)    echo "$HOME/.codex/skills" ;;
    agents)   echo "$HOME/.agents/skills" ;;
    cursor)   echo "$HOME/.cursor/skills" ;;
    gemini)   echo "$HOME/.gemini/skills" ;;
    opencode) echo "$HOME/.config/opencode/skills" ;;
    *) echo "未知目标: ${1}（可选: claude codex agents cursor gemini opencode）" >&2; return 1 ;;
  esac
}

DEFAULT_TARGETS="claude codex agents"
EXTRA_TARGETS="cursor gemini opencode"
ALL_TARGETS="claude codex agents cursor gemini opencode"

usage() {
  cat <<'EOF'
用法:
  ./install-skills.sh                       # 安装到默认目标: claude、codex、agents
  ./install-skills.sh --all                 # 追加 cursor、gemini、opencode
  ./install-skills.sh --target claude,codex # 只安装到指定目标
  ./install-skills.sh --list                # 只列出 skill 与目标，不做改动
EOF
}

# 只把根目录带 SKILL.md 的子目录视为可安装 skill；
# 参考库（如 apple-skills / macos-app-skills，根目录无 SKILL.md）天然被排除。
discover_skills() {
  local d
  for d in "$SKILLS_ROOT"/*/; do
    [ -f "${d}SKILL.md" ] && printf '%s\n' "$(basename "$d")"
  done
}

TARGETS=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all)     TARGETS="$ALL_TARGETS"; shift ;;
    --target)  [ $# -ge 2 ] || { echo "--target 需要值" >&2; exit 1; }
               TARGETS="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done
[ -n "$TARGETS" ] || TARGETS="$DEFAULT_TARGETS"

# 校验目标名，尽早失败
for t in $TARGETS; do target_dir "$t" >/dev/null; done

SKILLS="$(discover_skills)"
if [ -z "$SKILLS" ]; then
  echo "未在 $SKILLS_ROOT 发现任何含 SKILL.md 的 skill 目录" >&2
  exit 1
fi

if [ "$LIST_ONLY" = "1" ]; then
  echo "可安装 skill（${SKILLS_ROOT}）:"
  echo "$SKILLS" | sed 's/^/  - /'
  echo "安装目标:"
  for t in $TARGETS; do echo "  - $t -> $(target_dir "$t")"; done
  exit 0
fi

echo "安装 ${SKILLS_ROOT} 下的 skill 到: $(echo "$TARGETS" | tr '\n' ' ')"
CONFLICTS=0
for t in $TARGETS; do
  dest_dir="$(target_dir "$t")"
  mkdir -p "$dest_dir"
  for skill in $SKILLS; do
    dest="$dest_dir/$skill"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      echo "  [跳过] $dest 已存在且不是软链（真目录/真文件），未覆盖"
      CONFLICTS=$((CONFLICTS + 1))
      continue
    fi
    # -n：dest 是指向目录的软链时替换链本身而不是钻进目录内创建
    ln -sfn "$SKILLS_ROOT/$skill" "$dest"
    echo "  [安装] $dest -> $SKILLS_ROOT/$skill"
  done
done

if [ "$CONFLICTS" -gt 0 ]; then
  echo "完成，但 $CONFLICTS 处冲突被跳过；如需接管请手动确认后删除旧目录再重跑。"
  exit 1
fi
echo "完成。重启 / 重载各 agent 工具后生效。"
