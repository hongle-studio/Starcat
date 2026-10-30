#!/usr/bin/env bash

# 将一组 GitHub Issues 批量、幂等地同步到同一个 Project V2。
# 关键约束：Project、字段和 item 列表只读取一次，避免逐 Issue 全量扫描耗尽
# GraphQL 配额；所有 ID 仍按 profile 中的稳定名称动态解析，不写死远端 ID。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROFILE="${SCRIPT_DIR}/../references/project-profiles.json"
GH_BIN="${GH_BIN:-gh}"
JQ_BIN="${JQ_BIN:-jq}"

manifest_path=""
profile_path="$DEFAULT_PROFILE"
settle_seconds_override=""
dry_run=0

usage() {
  cat <<'EOF'
Usage:
  project-bulk-sync.sh --manifest PATH [options]

Manifest:
  A JSON array whose entries contain repo, issue, and optional phase, status,
  workType, and area fields. All entries must resolve to the same Project.

Options:
  --manifest PATH       Read the JSON manifest from PATH; use - for stdin.
  --profile PATH        Use another Project profile JSON file.
  --settle-seconds N    Override the single wait before final verification.
  --dry-run             Resolve and validate without remote mutations.
  -h, --help            Show this help.
EOF
}

log() {
  printf '[project-bulk-sync] %s\n' "$*"
}

die() {
  printf '[project-bulk-sync] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || die "--manifest requires a value"
      manifest_path="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile_path="$2"
      shift 2
      ;;
    --settle-seconds)
      [[ $# -ge 2 ]] || die "--settle-seconds requires a value"
      settle_seconds_override="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$manifest_path" ]] || die "--manifest is required"
[[ -r "$profile_path" ]] || die "profile is not readable: $profile_path"
if [[ "$manifest_path" != "-" ]]; then
  [[ -r "$manifest_path" ]] || die "manifest is not readable: $manifest_path"
fi

require_command "$JQ_BIN"
require_command "$GH_BIN"
"$GH_BIN" auth status >/dev/null 2>&1 || die "GitHub authentication failed"

if [[ "$manifest_path" == "-" ]]; then
  manifest_json="$(cat)"
else
  manifest_json="$(cat "$manifest_path")"
fi
printf '%s' "$manifest_json" | "$JQ_BIN" -e 'type == "array" and length > 0' >/dev/null \
  || die "manifest must be a non-empty JSON array"

profile_for_repo() {
  local repo="$1"
  local owner="${repo%%/*}"
  "$JQ_BIN" -c --arg repo "$repo" --arg owner "$owner" \
    '.repositories[$repo] // .organizations[$owner] // null' "$profile_path"
}

canonical_profile=""
canonical_signature=""
resolved_entries='[]'

while IFS= read -r entry; do
  repo="$(printf '%s' "$entry" | "$JQ_BIN" -r '.repo // empty')"
  issue_number="$(printf '%s' "$entry" | "$JQ_BIN" -r '.issue // empty')"
  phase="$(printf '%s' "$entry" | "$JQ_BIN" -r '.phase // empty')"
  status_value="$(printf '%s' "$entry" | "$JQ_BIN" -r '.status // empty')"
  work_type_value="$(printf '%s' "$entry" | "$JQ_BIN" -r '.workType // empty')"
  area_value="$(printf '%s' "$entry" | "$JQ_BIN" -r '.area // empty')"

  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $repo"
  [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || die "invalid issue number for $repo: $issue_number"
  [[ -z "$phase" || -z "$status_value" ]] || die "$repo#$issue_number combines phase and status"

  repo_profile="$(profile_for_repo "$repo")" || die "invalid profile JSON: $profile_path"
  [[ "$repo_profile" != "null" ]] || die "repository is not configured: $repo"
  signature="$(printf '%s' "$repo_profile" | "$JQ_BIN" -c '{project, fields, phases, itemLimit, newItemSettleSeconds, verificationDelaySeconds}')"
  if [[ -z "$canonical_profile" ]]; then
    canonical_profile="$repo_profile"
    canonical_signature="$signature"
  else
    [[ "$signature" == "$canonical_signature" ]] \
      || die "all manifest entries must resolve to the same Project profile"
  fi

  if [[ -n "$phase" ]]; then
    status_value="$(printf '%s' "$repo_profile" | "$JQ_BIN" -r --arg phase "$phase" '.phases[$phase] // empty')"
    [[ -n "$status_value" ]] || die "phase is not configured for $repo: $phase"
  fi

  # REST 读取不占用 GraphQL 配额，并且能在批量 Project 写入前验证 Issue 身份与状态。
  issue_json="$("$GH_BIN" api "repos/$repo/issues/$issue_number")" \
    || die "cannot resolve issue $repo#$issue_number"
  issue_url="$(printf '%s' "$issue_json" | "$JQ_BIN" -er '.html_url')" \
    || die "issue response is missing html_url: $repo#$issue_number"
  issue_state="$(printf '%s' "$issue_json" | "$JQ_BIN" -er '.state')" \
    || die "issue response is missing state: $repo#$issue_number"
  if [[ "$phase" == "completed" ]]; then
    [[ "$issue_state" == "closed" ]] || die "completed phase requires a closed issue: $repo#$issue_number"
  elif [[ -n "$phase" ]]; then
    [[ "$issue_state" == "open" ]] || die "$phase phase requires an open issue: $repo#$issue_number"
  fi

  resolved_entries="$(printf '%s' "$resolved_entries" | "$JQ_BIN" -c \
    --arg repo "$repo" \
    --argjson issue "$issue_number" \
    --arg url "$issue_url" \
    --arg status "$status_value" \
    --arg workType "$work_type_value" \
    --arg area "$area_value" \
    '. + [{repo: $repo, issue: $issue, url: $url, status: $status, workType: $workType, area: $area, itemId: "", newItem: false}]')"
done < <(printf '%s' "$manifest_json" | "$JQ_BIN" -c '.[]')

project_owner="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.project.owner')" \
  || die "profile is missing project.owner"
project_number="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.project.number')" \
  || die "profile is missing project.number"
status_field="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.fields.status')" \
  || die "profile is missing fields.status"
work_type_field="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.fields.workType')" \
  || die "profile is missing fields.workType"
area_field="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.fields.area')" \
  || die "profile is missing fields.area"
item_limit="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.itemLimit // 10000')"
settle_seconds="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.newItemSettleSeconds // 3')"
verification_delay="$(printf '%s' "$canonical_profile" | "$JQ_BIN" -er '.verificationDelaySeconds // 2')"
if [[ -n "$settle_seconds_override" ]]; then
  settle_seconds="$settle_seconds_override"
fi
for numeric_value in "$item_limit" "$settle_seconds" "$verification_delay"; do
  is_non_negative_integer "$numeric_value" || die "profile timing and limit values must be non-negative integers"
done
[[ "$item_limit" -gt 0 ]] || die "itemLimit must be greater than zero"

project_json="$("$GH_BIN" project view "$project_number" --owner "$project_owner" --format json)" \
  || die "cannot read project $project_owner/$project_number"
project_id="$(printf '%s' "$project_json" | "$JQ_BIN" -er '.id')" || die "project response is missing id"
project_closed="$(printf '%s' "$project_json" | "$JQ_BIN" -r '.closed')" || die "project response is missing closed state"
[[ "$project_closed" == "false" ]] || die "project is closed or returned an invalid state"

fields_json="$("$GH_BIN" project field-list "$project_number" --owner "$project_owner" --format json --limit 1000)" \
  || die "cannot read project fields"
field_returned="$(printf '%s' "$fields_json" | "$JQ_BIN" -er '.fields | length')"
field_total="$(printf '%s' "$fields_json" | "$JQ_BIN" -er '.totalCount')"
[[ "$field_returned" -eq "$field_total" ]] \
  || die "project field pagination is incomplete: returned=$field_returned total=$field_total"

items_json=""
load_items() {
  local returned total
  items_json="$("$GH_BIN" project item-list "$project_number" --owner "$project_owner" --format json --limit "$item_limit")" \
    || die "cannot read project items"
  returned="$(printf '%s' "$items_json" | "$JQ_BIN" -er '.items | length')"
  total="$(printf '%s' "$items_json" | "$JQ_BIN" -er '.totalCount')"
  [[ "$returned" -ge "$total" ]] \
    || die "project item pagination is incomplete: returned=$returned total=$total limit=$item_limit"
}

find_item_id() {
  local url="$1"
  local count
  count="$(printf '%s' "$items_json" | "$JQ_BIN" -r --arg url "$url" '[.items[] | select(.content.url == $url)] | length')"
  [[ "$count" -le 1 ]] || die "multiple project items reference the same issue: $url"
  printf '%s' "$items_json" | "$JQ_BIN" -r --arg url "$url" \
    '[.items[] | select(.content.url == $url) | .id] | if length == 1 then .[0] else empty end'
}

load_items

# 先解析或添加全部 item；此阶段不在每个 Issue 后重新拉取整个 Project。
while IFS= read -r entry; do
  url="$(printf '%s' "$entry" | "$JQ_BIN" -r '.url')"
  repo="$(printf '%s' "$entry" | "$JQ_BIN" -r '.repo')"
  issue_number="$(printf '%s' "$entry" | "$JQ_BIN" -r '.issue')"
  item_id="$(find_item_id "$url")"
  new_item=false
  if [[ -z "$item_id" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      item_id="__dry_run__${repo}#${issue_number}"
      log "dry-run: would add $repo#$issue_number"
    else
      add_output="$("$GH_BIN" project item-add "$project_number" --owner "$project_owner" --url "$url" --format json)" \
        || die "cannot add project item: $repo#$issue_number"
      item_id="$(printf '%s' "$add_output" | "$JQ_BIN" -r '.id // empty')"
      [[ -n "$item_id" ]] || die "item-add returned no item id: $repo#$issue_number"
      new_item=true
      log "added: $repo#$issue_number item=$item_id"
    fi
  else
    log "found: $repo#$issue_number item=$item_id"
  fi
  resolved_entries="$(printf '%s' "$resolved_entries" | "$JQ_BIN" -c \
    --arg url "$url" --arg id "$item_id" --argjson newItem "$new_item" \
    'map(if .url == $url then .itemId = $id | .newItem = $newItem else . end)')"
done < <(printf '%s' "$resolved_entries" | "$JQ_BIN" -c '.[]')

resolved_field_id=""
resolved_option_id=""
resolve_single_select() {
  local field_name="$1"
  local option_name="$2"
  local field_count option_count field_type
  field_count="$(printf '%s' "$fields_json" | "$JQ_BIN" -r --arg name "$field_name" '[.fields[] | select(.name == $name)] | length')"
  [[ "$field_count" -eq 1 ]] || die "expected exactly one project field named '$field_name', found $field_count"
  field_type="$(printf '%s' "$fields_json" | "$JQ_BIN" -r --arg name "$field_name" '.fields[] | select(.name == $name) | .type')"
  [[ "$field_type" == "ProjectV2SingleSelectField" ]] || die "project field '$field_name' is not single-select"
  option_count="$(printf '%s' "$fields_json" | "$JQ_BIN" -r --arg field "$field_name" --arg option "$option_name" '[.fields[] | select(.name == $field) | .options[] | select(.name == $option)] | length')"
  [[ "$option_count" -eq 1 ]] || die "expected exactly one '$field_name' option named '$option_name', found $option_count"
  resolved_field_id="$(printf '%s' "$fields_json" | "$JQ_BIN" -r --arg name "$field_name" '.fields[] | select(.name == $name) | .id')"
  resolved_option_id="$(printf '%s' "$fields_json" | "$JQ_BIN" -r --arg field "$field_name" --arg option "$option_name" '.fields[] | select(.name == $field) | .options[] | select(.name == $option) | .id')"
}

current_field_value() {
  local item_id="$1"
  local field_name="$2"
  local first field_key
  first="$(printf '%s' "${field_name:0:1}" | tr '[:upper:]' '[:lower:]')"
  field_key="${first}${field_name:1}"
  printf '%s' "$items_json" | "$JQ_BIN" -r --arg id "$item_id" --arg key "$field_key" \
    '.items[] | select(.id == $id) | .[$key] // empty'
}

edit_single_select() {
  local item_id="$1"
  local field_name="$2"
  local desired_value="$3"
  [[ -n "$desired_value" ]] || return 0
  resolve_single_select "$field_name" "$desired_value"
  if [[ "$dry_run" -eq 1 ]]; then
    log "dry-run: would set item=$item_id $field_name='$desired_value'"
    return 0
  fi
  "$GH_BIN" project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$resolved_field_id" \
    --single-select-option-id "$resolved_option_id" \
    --format json >/dev/null \
    || die "cannot set item=$item_id $field_name='$desired_value'"
}

# 使用首次快照跳过已一致字段；新 item 在快照中不存在，因此会写入所有目标字段。
changed_count=0
while IFS= read -r entry; do
  item_id="$(printf '%s' "$entry" | "$JQ_BIN" -r '.itemId')"
  new_item="$(printf '%s' "$entry" | "$JQ_BIN" -r '.newItem')"
  for pair in "${status_field}:status" "${work_type_field}:workType" "${area_field}:area"; do
    field_name="${pair%%:*}"
    value_key="${pair#*:}"
    desired_value="$(printf '%s' "$entry" | "$JQ_BIN" -r --arg key "$value_key" '.[$key] // empty')"
    [[ -n "$desired_value" ]] || continue
    current_value=""
    # dry-run 也使用已读取的 Project 快照判断 no-op；只有尚未真实添加的
    # __dry_run__ item 没有当前值，必须报告为计划写入。
    if [[ "$new_item" != "true" && "$item_id" != __dry_run__* ]]; then
      current_value="$(current_field_value "$item_id" "$field_name")"
    fi
    if [[ "$current_value" != "$desired_value" ]]; then
      edit_single_select "$item_id" "$field_name" "$desired_value"
      changed_count=$((changed_count + 1))
    fi
  done
done < <(printf '%s' "$resolved_entries" | "$JQ_BIN" -c '.[]')

if [[ "$dry_run" -eq 1 ]]; then
  log "dry-run complete: entries=$(printf '%s' "$resolved_entries" | "$JQ_BIN" -r 'length')"
  exit 0
fi

if [[ "$settle_seconds" -gt 0 ]]; then
  # 所有 item 添加完成后只等待一次，吸收 built-in workflow 的晚到 Backlog 写入。
  sleep "$settle_seconds"
fi
load_items

retry_count=0
verify_entry() {
  local entry="$1"
  local allow_retry="$2"
  local repo issue_number url item_id field_name value_key desired_value current_value pair
  repo="$(printf '%s' "$entry" | "$JQ_BIN" -r '.repo')"
  issue_number="$(printf '%s' "$entry" | "$JQ_BIN" -r '.issue')"
  url="$(printf '%s' "$entry" | "$JQ_BIN" -r '.url')"
  item_id="$(find_item_id "$url")"
  [[ -n "$item_id" ]] || die "project item missing after synchronization: $repo#$issue_number"
  for pair in "${status_field}:status" "${work_type_field}:workType" "${area_field}:area"; do
    field_name="${pair%%:*}"
    value_key="${pair#*:}"
    desired_value="$(printf '%s' "$entry" | "$JQ_BIN" -r --arg key "$value_key" '.[$key] // empty')"
    [[ -n "$desired_value" ]] || continue
    current_value="$(current_field_value "$item_id" "$field_name")"
    if [[ "$current_value" != "$desired_value" ]]; then
      [[ "$allow_retry" == "true" ]] \
        || die "verification failed for $repo#$issue_number $field_name: expected='$desired_value' actual='$current_value'"
      edit_single_select "$item_id" "$field_name" "$desired_value"
      retry_count=$((retry_count + 1))
    fi
  done
}

while IFS= read -r entry; do
  verify_entry "$entry" true
done < <(printf '%s' "$resolved_entries" | "$JQ_BIN" -c '.[]')

if [[ "$retry_count" -gt 0 ]]; then
  if [[ "$verification_delay" -gt 0 ]]; then
    sleep "$verification_delay"
  fi
  load_items
fi
while IFS= read -r entry; do
  verify_entry "$entry" false
done < <(printf '%s' "$resolved_entries" | "$JQ_BIN" -c '.[]')

entry_count="$(printf '%s' "$resolved_entries" | "$JQ_BIN" -r 'length')"
log "sync complete: entries=$entry_count field_updates=$changed_count verification_retries=$retry_count"
