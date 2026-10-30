#!/usr/bin/env bash

# 将一个 GitHub Issue 幂等同步到已配置的 Project V2。
# 关键约束：只按 profile 中的稳定名称解析字段，绝不硬编码 GraphQL ID；
# 在 item 列表没有完整取回时拒绝添加，避免分页遗漏造成重复 item。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROFILE="${SCRIPT_DIR}/../references/project-profiles.json"
GH_BIN="${GH_BIN:-gh}"
JQ_BIN="${JQ_BIN:-jq}"

repo=""
issue_number=""
phase=""
status_value=""
work_type_value=""
area_value=""
profile_path="$DEFAULT_PROFILE"
wait_seconds_override=""
dry_run=0

usage() {
  cat <<'EOF'
Usage:
  project-sync.sh --repo OWNER/REPO --issue NUMBER [options]

Options:
  --phase PHASE          Map a lifecycle phase to Status through the profile.
  --status STATUS        Set Status directly; cannot be combined with --phase.
  --work-type VALUE      Set the configured Work Type single-select field.
  --area VALUE           Set the configured Area single-select field.
  --profile PATH         Use another project profile JSON file.
  --wait-seconds N       Override how long to wait for GitHub auto-add.
  --dry-run              Resolve and validate without remote mutations.
  -h, --help             Show this help.
EOF
}

log() {
  printf '[project-sync] %s\n' "$*"
}

die() {
  printf '[project-sync] error: %s\n' "$*" >&2
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
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --issue)
      [[ $# -ge 2 ]] || die "--issue requires a value"
      issue_number="$2"
      shift 2
      ;;
    --phase)
      [[ $# -ge 2 ]] || die "--phase requires a value"
      phase="$2"
      shift 2
      ;;
    --status)
      [[ $# -ge 2 ]] || die "--status requires a value"
      status_value="$2"
      shift 2
      ;;
    --work-type)
      [[ $# -ge 2 ]] || die "--work-type requires a value"
      work_type_value="$2"
      shift 2
      ;;
    --area)
      [[ $# -ge 2 ]] || die "--area requires a value"
      area_value="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile_path="$2"
      shift 2
      ;;
    --wait-seconds)
      [[ $# -ge 2 ]] || die "--wait-seconds requires a value"
      wait_seconds_override="$2"
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

[[ -n "$repo" ]] || die "--repo is required"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $repo"
[[ -n "$issue_number" ]] || die "--issue is required"
[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || die "invalid issue number: $issue_number"
[[ -z "$phase" || -z "$status_value" ]] || die "--phase and --status cannot be combined"
[[ -r "$profile_path" ]] || die "profile is not readable: $profile_path"

require_command "$JQ_BIN"

repo_owner="${repo%%/*}"
# 精确仓库配置优先；organization 配置用于多个同组织仓库共享同一 Project，
# 避免为每个支撑仓库复制一份完全相同且容易漂移的字段映射。
repo_profile="$($JQ_BIN -c --arg repo "$repo" --arg owner "$repo_owner" \
  '.repositories[$repo] // .organizations[$owner] // null' "$profile_path")" || die "invalid profile JSON: $profile_path"
if [[ "$repo_profile" == "null" ]]; then
  log "skipped: repository is not configured: $repo"
  exit 0
fi

require_command "$GH_BIN"
"$GH_BIN" auth status >/dev/null 2>&1 || die "GitHub authentication failed"

project_owner="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.project.owner')" || die "profile is missing project.owner"
project_number="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.project.number')" || die "profile is missing project.number"
status_field="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.fields.status')" || die "profile is missing fields.status"
work_type_field="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.fields.workType')" || die "profile is missing fields.workType"
area_field="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.fields.area')" || die "profile is missing fields.area"
item_limit="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.itemLimit // 10000')" || die "invalid itemLimit"
wait_seconds="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.autoAddWaitSeconds // 8')" || die "invalid autoAddWaitSeconds"
settle_seconds="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.newItemSettleSeconds // 3')" || die "invalid newItemSettleSeconds"
verification_delay="$(printf '%s' "$repo_profile" | "$JQ_BIN" -er '.verificationDelaySeconds // 2')" || die "invalid verificationDelaySeconds"

if [[ -n "$wait_seconds_override" ]]; then
  wait_seconds="$wait_seconds_override"
fi
for numeric_value in "$item_limit" "$wait_seconds" "$settle_seconds" "$verification_delay"; do
  is_non_negative_integer "$numeric_value" || die "profile timing and limit values must be non-negative integers"
done
[[ "$item_limit" -gt 0 ]] || die "itemLimit must be greater than zero"

if [[ -n "$phase" ]]; then
  status_value="$(printf '%s' "$repo_profile" | "$JQ_BIN" -r --arg phase "$phase" '.phases[$phase] // empty')"
  [[ -n "$status_value" ]] || die "phase is not configured for $repo: $phase"
fi

issue_json="$("$GH_BIN" issue view "$issue_number" --repo "$repo" --json url,state,title)" || die "cannot resolve issue $repo#$issue_number"
issue_url="$(printf '%s' "$issue_json" | "$JQ_BIN" -er '.url')" || die "issue response is missing url"
issue_state="$(printf '%s' "$issue_json" | "$JQ_BIN" -er '.state')" || die "issue response is missing state"
if [[ "$phase" == "completed" ]]; then
  [[ "$issue_state" == "CLOSED" ]] || die "completed phase requires a closed issue: $repo#$issue_number"
elif [[ -n "$phase" ]]; then
  [[ "$issue_state" == "OPEN" ]] || die "$phase phase requires an open issue: $repo#$issue_number"
fi

project_json="$("$GH_BIN" project view "$project_number" --owner "$project_owner" --format json)" || die "cannot read project $project_owner/$project_number"
project_id="$(printf '%s' "$project_json" | "$JQ_BIN" -er '.id')" || die "project response is missing id"
project_closed="$(printf '%s' "$project_json" | "$JQ_BIN" -r '.closed')" || die "project response is missing closed state"
[[ "$project_closed" == "false" ]] || die "project is closed or returned an invalid state: $project_owner/$project_number"
fields_json="$("$GH_BIN" project field-list "$project_number" --owner "$project_owner" --format json --limit 1000)" || die "cannot read project fields"
field_returned="$(printf '%s' "$fields_json" | "$JQ_BIN" -er '.fields | length')" || die "invalid project field response"
field_total="$(printf '%s' "$fields_json" | "$JQ_BIN" -er '.totalCount')" || die "project field response is missing totalCount"
[[ "$field_returned" -eq "$field_total" ]] || die "project field pagination is incomplete: returned=$field_returned total=$field_total"

items_json=""
item_id=""
item_was_added=0
changed_any=0

load_items() {
  local returned total
  items_json="$("$GH_BIN" project item-list "$project_number" --owner "$project_owner" --format json --limit "$item_limit")" || die "cannot read project items"
  returned="$(printf '%s' "$items_json" | "$JQ_BIN" -er '.items | length')" || die "invalid project item response"
  total="$(printf '%s' "$items_json" | "$JQ_BIN" -er '.totalCount')" || die "project item response is missing totalCount"
  if [[ "$returned" -lt "$total" ]]; then
    die "project item pagination is incomplete: returned=$returned total=$total limit=$item_limit"
  fi
}

find_item() {
  local match_count
  item_id="$(printf '%s' "$items_json" | "$JQ_BIN" -r --arg url "$issue_url" '[.items[] | select(.content.url == $url) | .id] | if length == 1 then .[0] else empty end')"
  match_count="$(printf '%s' "$items_json" | "$JQ_BIN" -r --arg url "$issue_url" '[.items[] | select(.content.url == $url)] | length')"
  [[ "$match_count" -le 1 ]] || die "multiple project items reference the same issue: $issue_url"
}

load_items
find_item

if [[ -z "$item_id" && "$wait_seconds" -gt 0 ]]; then
  log "waiting up to ${wait_seconds}s for Project auto-add"
  deadline=$((SECONDS + wait_seconds))
  while [[ -z "$item_id" && "$SECONDS" -lt "$deadline" ]]; do
    sleep 1
    load_items
    find_item
  done
fi

if [[ -z "$item_id" ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    log "dry-run: would add $issue_url to $project_owner project #$project_number"
    item_id="__dry_run_new_item__"
  else
    add_output=""
    if ! add_output="$("$GH_BIN" project item-add "$project_number" --owner "$project_owner" --url "$issue_url" --format json)"; then
      # auto-add 可能和 item-add 发生竞争；失败后重新读取，确认是否已经由 workflow 加入。
      load_items
      find_item
      [[ -n "$item_id" ]] || die "cannot add project item"
    else
      item_id="$(printf '%s' "$add_output" | "$JQ_BIN" -r '.id // empty')"
      if [[ -z "$item_id" ]]; then
        load_items
        find_item
      fi
      [[ -n "$item_id" ]] || die "item-add succeeded but no item id was returned"
      item_was_added=1
      log "added issue to project: $item_id"
    fi
  fi
else
  log "project item already exists: $item_id"
fi

if [[ "$item_was_added" -eq 1 && "$settle_seconds" -gt 0 ]]; then
  # Project 的 item-added workflow 可能稍后写入 Backlog；先等待再写目标状态，避免被异步覆盖。
  sleep "$settle_seconds"
  load_items
  find_item
  [[ -n "$item_id" ]] || die "new project item disappeared before field update"
fi

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
  local field_name="$1"
  local first field_key
  first="$(printf '%s' "${field_name:0:1}" | tr '[:upper:]' '[:lower:]')"
  field_key="${first}${field_name:1}"
  printf '%s' "$items_json" | "$JQ_BIN" -r --arg id "$item_id" --arg key "$field_key" '.items[] | select(.id == $id) | .[$key] // empty'
}

set_single_select() {
  local field_name="$1"
  local desired_value="$2"
  local current_value
  [[ -n "$desired_value" ]] || return 0

  resolve_single_select "$field_name" "$desired_value"
  if [[ "$item_id" == "__dry_run_new_item__" ]]; then
    current_value=""
  else
    current_value="$(current_field_value "$field_name")"
  fi

  if [[ "$current_value" == "$desired_value" ]]; then
    log "unchanged: $field_name=$desired_value"
    return 0
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "dry-run: would set $field_name='$desired_value' (current='${current_value}')"
    return 0
  fi

  "$GH_BIN" project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$resolved_field_id" \
    --single-select-option-id "$resolved_option_id" \
    --format json >/dev/null || die "cannot set $field_name='$desired_value'"
  changed_any=1
  load_items
  find_item
  current_value="$(current_field_value "$field_name")"
  [[ "$current_value" == "$desired_value" ]] || die "verification failed for $field_name: expected='$desired_value' actual='$current_value'"
  log "updated: $field_name=$desired_value"
}

sync_all_fields() {
  set_single_select "$status_field" "$status_value"
  set_single_select "$work_type_field" "$work_type_value"
  set_single_select "$area_field" "$area_value"
}

sync_all_fields

if [[ "$dry_run" -eq 0 && "$changed_any" -eq 1 && "$verification_delay" -gt 0 ]]; then
  # 延迟回读并再次幂等同步，用于抵消 Project built-in workflow 的晚到写入。
  sleep "$verification_delay"
  load_items
  find_item
  sync_all_fields
fi

if [[ "$dry_run" -eq 1 ]]; then
  log "dry-run complete: $repo#$issue_number"
else
  log "sync complete: $repo#$issue_number item=$item_id"
fi
