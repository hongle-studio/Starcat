#!/usr/bin/env bash
#
# track-upstream.sh
# 自动跟踪 Starcat 官方上游 (upstream) 源码更新并发送 macOS 原生系统通知。
#

set -uo pipefail

REPO_DIR="/Users/dinghongwu/projects/02-开源改造/Starcat"
LOG_FILE="${REPO_DIR}/.upstream-tracker.log"
STATE_FILE="${REPO_DIR}/.upstream-tracker.state"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$(dirname "$LOG_FILE")"
cd "$REPO_DIR"

# 自动适配本地代理（保障 launchd 无头运行时能顺畅访问 GitHub）
for proxy_port in 7895 7897 7890; do
    if nc -z 127.0.0.1 "$proxy_port" 2>/dev/null; then
        export http_proxy="http://127.0.0.1:${proxy_port}"
        export https_proxy="http://127.0.0.1:${proxy_port}"
        export all_proxy="socks5://127.0.0.1:${proxy_port}"
        break
    fi
done

# 确保 upstream 存在
if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream https://github.com/starcat-app/Starcat.git
fi

# 抓取上游最新提交和 tags（带重试与容错）
FETCH_SUCCESS=0
for i in 1 2; do
    if git fetch upstream --tags --quiet 2>/dev/null; then
        FETCH_SUCCESS=1
        break
    fi
    sleep 2
done

if [ "$FETCH_SUCCESS" -ne 1 ]; then
    echo "[${TIMESTAMP}] 警告：连接 GitHub 抓取上游更新超时或失败，本次跳过。" >> "$LOG_FILE"
    exit 0
fi

# 获取当前分支与 upstream/main 的差距
LOCAL_HEAD="$(git rev-parse HEAD)"
UPSTREAM_HEAD="$(git rev-parse upstream/main)"
LOCAL_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "无")"

# 获取官方最新的正式版本 tag（排除 -dev 预发布版）
OFFICIAL_LATEST_STABLE="$(git tag --list 'v*.*.*' --sort=-v:refname | grep -v -- '-dev' | head -n 1 || echo "无")"
OFFICIAL_LATEST_ANY="$(git tag --list 'v*' --sort=-v:refname | head -n 1 || echo "无")"

BEHIND_COUNT="$(git rev-list --count HEAD..upstream/main 2>/dev/null || echo 0)"

# 读取上次已通知状态
LAST_STATE=""
if [ -f "$STATE_FILE" ]; then
    LAST_STATE="$(cat "$STATE_FILE")"
fi

CURRENT_STATE="UPSTREAM_HEAD=${UPSTREAM_HEAD}|STABLE=${OFFICIAL_LATEST_STABLE}|ANY=${OFFICIAL_LATEST_ANY}|BEHIND=${BEHIND_COUNT}"

# 如果 upstream 领先，或者官方发布了高于本地的正式 tag
if [ "$BEHIND_COUNT" -gt 0 ] || [ "$LOCAL_TAG" != "$OFFICIAL_LATEST_STABLE" ]; then
    if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
        DETAILS="官方主干领先 ${BEHIND_COUNT} 个提交，最新正式版: ${OFFICIAL_LATEST_STABLE} (本地: ${LOCAL_TAG})。"
        
        {
            echo "=========================================="
            echo "[${TIMESTAMP}] 发现官方源码更新！"
            echo "${DETAILS}"
            if [ "$BEHIND_COUNT" -gt 0 ]; then
                echo "新增上游提交日志："
                git log HEAD..upstream/main --oneline -n 5
            fi
            echo "=========================================="
        } >> "$LOG_FILE"
        
        # 发送 macOS 系统原生横幅通知
        osascript -e "display notification \"${DETAILS}\" with title \"Starcat 源码更新\" subtitle \"检测到官方新代码/新版本\" sound name \"Glass\""
        
        echo "$CURRENT_STATE" > "$STATE_FILE"
        echo "[${TIMESTAMP}] 发现新更新已通知：${DETAILS}"
    else
        echo "[${TIMESTAMP}] 检测到上游有更新，但此前已提醒过，跳过重复通知。" >> "$LOG_FILE"
        echo "[${TIMESTAMP}] 已提醒过，静默跳过。"
    fi
else
    echo "[${TIMESTAMP}] 检查完毕：本地源码与官方 upstream/main 保持完全同步 (Tag: ${LOCAL_TAG})。" >> "$LOG_FILE"
    echo "$CURRENT_STATE" > "$STATE_FILE"
    echo "[${TIMESTAMP}] 本地代码已是最新。"
fi
