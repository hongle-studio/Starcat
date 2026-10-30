#!/usr/bin/env bash
# Starcat skills 卸载脚本
#
# 作用：删除各 agent 工具用户级全局 skills 目录里「指向本仓库 skills/」的软链。
# 安全边界：只删软链，且只删解析后落在本仓库 skills/ 内的软链；
#           任何真目录、真文件、指向其它位置的软链（如 skills CLI 管理的）一律不碰。
#
# 用法：
#   ./uninstall-skills.sh                # 扫描全部已知目标目录（默认，能清干净残留）
#   ./uninstall-skills.sh --target codex # 只清理指定目标
#   ./uninstall-skills.sh --list         # 只列出将被删除的软链，不做改动
set -euo pipefail

SKILLS_ROOT="$(cd "$(dirname "$0")" && pwd)"

# 与 install-skills.sh 保持一致的目标集合；卸载默认扫全部，避免换目标后留残留。
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

ALL_TARGETS="claude codex agents cursor gemini opencode"

usage() {
  cat <<'EOF'
用法:
  ./uninstall-skills.sh                # 扫描全部已知目标目录（默认，能清干净残留）
  ./uninstall-skills.sh --target codex # 只清理指定目标
  ./uninstall-skills.sh --list         # 只列出将被删除的软链，不做改动
EOF
}

# 判断某软链是否指向本仓库 skills/ 内；是则输出归一化后的目标路径，否则返回 1。
# install-skills.sh 只创建绝对路径软链，但这里仍把相对链接解析后再比对，
# 避免误删/漏删由其它工具以相对路径写入的链接。
resolve_if_ours() {
  local entry="$1" link_target resolved
  link_target="$(readlink "$entry")"
  case "$link_target" in
    /*) resolved="$link_target" ;;
    *)  resolved="$(cd "$(dirname "$entry")/$(dirname "$link_target")" 2>/dev/null && pwd)/$(basename "$link_target")" || return 1 ;;
  esac
  case "$resolved" in
    "$SKILLS_ROOT"/*) echo "$resolved"; return 0 ;;
    *) return 1 ;;
  esac
}

TARGETS="$ALL_TARGETS"
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target)  [ $# -ge 2 ] || { echo "--target 需要值" >&2; exit 1; }
               TARGETS="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

# 校验目标名，尽早失败
for t in $TARGETS; do target_dir "$t" >/dev/null; done

REMOVED=0
for t in $TARGETS; do
  dest_dir="$(target_dir "$t")"
  [ -d "$dest_dir" ] || continue
  # 无匹配时 glob 保持字面量，[ -L ] 会过滤掉，无需 nullglob
  for entry in "$dest_dir"/*; do
    [ -L "$entry" ] || continue
    if resolved="$(resolve_if_ours "$entry")"; then
      if [ "$LIST_ONLY" = "1" ]; then
        echo "  [将删除] $entry -> $resolved"
      else
        rm "$entry"
        echo "  [已删除] $entry -> $resolved"
        REMOVED=$((REMOVED + 1))
      fi
    fi
  done
done

if [ "$LIST_ONLY" = "1" ]; then
  echo "预览完成，未做任何改动。"
else
  echo "完成：共删除 $REMOVED 个指向 $SKILLS_ROOT 的软链。"
fi
