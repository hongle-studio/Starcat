#!/usr/bin/env bash
#
# sync.sh - Starcat 一键同步三方代码（官方上游 -> 本地代码 -> 个人云端Fork）
#

set -euo pipefail

REPO_DIR="/Users/dinghongwu/projects/02-开源改造/Starcat"
cd "$REPO_DIR"

echo "=== 开始一键全链路同步 Starcat 源码 ==="

# 1. 自动适配本地代理
for proxy_port in 7895 7897 7890; do
    if nc -z 127.0.0.1 "$proxy_port" 2>/dev/null; then
        export http_proxy="http://127.0.0.1:${proxy_port}"
        export https_proxy="http://127.0.0.1:${proxy_port}"
        export all_proxy="socks5://127.0.0.1:${proxy_port}"
        echo "[*] 检测到本地代理已开启 (端口: ${proxy_port})"
        break
    fi
done

# 2. 拉取 upstream 与 origin 最新状态
echo "[*] 正在拉取官方上游 upstream 与个人 Fork origin 的最新提交与 Tags..."
git fetch upstream --tags --quiet
git fetch origin --quiet

# 3. 检查是否有未提交代码
if ! git diff-index --quiet HEAD --; then
    echo "[!] 警告：本地有未提交的代码修改，请先提交或暂存后再同步。"
    exit 1
fi

# 4. 同步 upstream 到本地 main
echo "[*] 正在将官方上游 (upstream/main) 合并到本地分支..."
git merge upstream/main -m "chore: sync upstream starcat-app/Starcat changes"

# 5. 推送到个人 Fork 仓库 (origin/main)
echo "[*] 正在将本地最新代码推送到个人云端仓库 (origin/main)..."
git push origin main --tags

TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "无")"
echo "=== 同步完成！当前本地基线版本：${TAG}，已与官方和云端完全对齐 ==="
