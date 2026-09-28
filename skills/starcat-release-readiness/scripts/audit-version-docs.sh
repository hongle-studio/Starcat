#!/bin/bash
# 只读审计 Starcat 主仓库与 supports 产品仓库中的版本文档语义。
# 只把仍承担“当前 / 最新 / 下载”语义的旧版本列为 stale candidate；历史发布记录只计数，不阻断。

set -u
shopt -s nocasematch

usage() {
  printf 'Usage: %s <starcat-root> <published-version> [previous-version]\n' "$0" >&2
}

fail() {
  printf 'ERROR\t%s\n' "$1" >&2
  exit 1
}

root=${1:-}
published_version=${2:-}
previous_version=${3:-}

[ -n "$root" ] && [ -n "$published_version" ] || {
  usage
  exit 1
}

[ -d "$root" ] || fail "Starcat root does not exist: $root"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v rg >/dev/null 2>&1 || fail "rg is required"
git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 || fail "Not a Git repository: $root"

printf '%s\n' "$published_version" | rg -q '^[0-9]+\.[0-9]+\.[0-9]+$' || \
  fail "Published version must use X.Y.Z: $published_version"

if [ -n "$previous_version" ]; then
  printf '%s\n' "$previous_version" | rg -q '^[0-9]+\.[0-9]+\.[0-9]+$' || \
    fail "Previous version must use X.Y.Z: $previous_version"
fi

root=$(cd "$root" && pwd -P)
repository_count=0
dirty_count=0
stale_count=0
historical_count=0
published_marker_count=0

repository_markers() {
  printf '%s\n' "$root/.git"
  if [ -d "$root/supports" ]; then
    find "$root/supports" -maxdepth 3 \( -type d -o -type f \) -name .git -print | sort
  fi
}

version_matches() {
  version=$1
  (
    cd "$repo" || exit 1
    git ls-files -co --exclude-standard -z | xargs -0 rg -n --no-heading -F "$version" \
      -g '*.md' -g '*.mdx' -g '*.html' -g '*.yml' -g '*.yaml' -g '*.py' -g '*.sh' \
      -g '*.json' -g '*.toml' -g '*.rb' -g '*.xml' -g '*.plist' -g '*.xcconfig' -- 2>/dev/null
  ) || true
}

is_historical_path() {
  case "$1" in
    CHANGELOG*|*/CHANGELOG*|*changelog*|*/appcast.xml|docs/3-*|docs/4-*) return 0 ;;
    *) return 1 ;;
  esac
}

has_current_semantics() {
  content=$1
  version=$2
  case "$content" in
    *current*|*latest*|*当前*|*最新版*|*placeholder*|*download-version*|*fallback*|*"Starcat-$version-arm64.dmg"*|*version\ "$version"\ includes*|version\ *|*shortVersionString*) return 0 ;;
    *) return 1 ;;
  esac
}

printf 'AUDIT\troot=%s\tpublished=%s\tprevious=%s\n' "$root" "$published_version" "${previous_version:-none}"

while IFS= read -r git_marker; do
  repo=${git_marker%/.git}
  if [ "$repo" = "$root" ]; then
    relative_repo=.
  else
    relative_repo=${repo#"$root"/}
    case "$relative_repo" in
      supports/.github) ;;
      */.*) continue ;;
    esac
  fi

  repository_count=$((repository_count + 1))
  branch=$(git -C "$repo" branch --show-current 2>/dev/null || true)
  head=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)
  status=$(git -C "$repo" status --porcelain=v1 2>/dev/null || true)
  dirty=no
  if [ -n "$status" ]; then
    dirty=yes
    dirty_count=$((dirty_count + 1))
  fi
  printf 'REPOSITORY\t%s\tbranch=%s\thead=%s\tdirty=%s\n' "$relative_repo" "${branch:-detached}" "${head:-unknown}" "$dirty"

  while IFS= read -r match; do
    relative_file=${match%%:*}
    remainder=${match#*:}
    line_number=${remainder%%:*}
    content=${remainder#*:}
    if ! is_historical_path "$relative_file" && has_current_semantics "$content" "$published_version"; then
      published_marker_count=$((published_marker_count + 1))
    fi
  done < <(version_matches "$published_version")

  if [ -n "$previous_version" ]; then
    while IFS= read -r match; do
      relative_file=${match%%:*}
      remainder=${match#*:}
      line_number=${remainder%%:*}
      content=${remainder#*:}
      if is_historical_path "$relative_file"; then
        historical_count=$((historical_count + 1))
      elif has_current_semantics "$content" "$previous_version"; then
        stale_count=$((stale_count + 1))
        printf 'STALE_CANDIDATE\t%s/%s:%s:%s\n' "$relative_repo" "$relative_file" "$line_number" "$content"
      else
        historical_count=$((historical_count + 1))
      fi
    done < <(version_matches "$previous_version")
  fi
done < <(repository_markers)

printf 'SUMMARY\trepositories=%s\tdirty=%s\tpublished_markers=%s\tstale_candidates=%s\thistorical_references=%s\n' \
  "$repository_count" "$dirty_count" "$published_marker_count" "$stale_count" "$historical_count"

if [ "$stale_count" -gt 0 ]; then
  exit 2
fi

exit 0
