#!/bin/zsh

# <swiftbar.title>Codex Model Presets</swiftbar.title>
# <swiftbar.version>v2.0.0</swiftbar.version>
# <swiftbar.desc>Switch Codex presets from the shared JSON configuration.</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

set -eu

readonly CODEX_CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
readonly CONFIG_FILE="$CODEX_CONFIG_DIR/config.toml"
readonly PRESETS_FILE="$CODEX_CONFIG_DIR/codex-presets.json"
readonly BACKUP_FILE="$CODEX_CONFIG_DIR/config.toml.swiftbar-backup"
readonly MAIN_STATE_FILE="$CODEX_CONFIG_DIR/codex-main-preset-state.json"
readonly SIDE_STATE_FILE="$CODEX_CONFIG_DIR/codex-side-preset-state.json"
readonly DIAGNOSTICS_FILE="$CODEX_CONFIG_DIR/codex-preset-diagnostics/latest.json"
readonly SCRIPT_FILE="${0:A}"
readonly HAMMERSPOON_DISPATCH_FILE="${SCRIPT_FILE:h}/codex-hammerspoon-dispatch.sh"
readonly JQ="/usr/bin/jq"

typeset -a PRESET_IDS PRESET_GROUPS
typeset -A PRESET_LABEL PRESET_GROUP PRESET_MODEL PRESET_EFFORT PRESET_KEY
integer CONFIG_VALID=1
typeset CONFIG_ERROR=""

read_setting() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  /usr/bin/awk -F '"' -v key="$1" \
    '$0 ~ "^" key "[[:space:]]*=" { print $2; exit }' "$CONFIG_FILE"
}

validate_presets() {
  [[ -x "$JQ" ]] || {
    CONFIG_ERROR="找不到 /usr/bin/jq"
    return 1
  }
  [[ -r "$PRESETS_FILE" ]] || {
    CONFIG_ERROR="找不到或无法读取 $PRESETS_FILE"
    return 1
  }
  "$JQ" -e '
    (.version == 1)
    and (.presets | type == "array" and length > 0)
    and ([.presets[] | select(
      ((.id | type) != "string") or
      ((.id | length) == 0) or
      ((.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not)) or
      ((.label | type) != "string") or ((.label | length) == 0) or
      ((.group | type) != "string") or ((.group | length) == 0) or
      ((.model | type) != "string") or ((.model | length) == 0) or
      ((.model_label | type) != "string") or ((.model_label | length) == 0) or
      ((.effort | type) != "string") or
      ((.effort as $effort | (["low", "medium", "high", "xhigh", "max", "ultra"] | index($effort))) == null) or
      ((.effort_index | type) != "number") or (.effort_index < 1) or ((.effort_index % 1) != 0) or
      ((.aliases | type) != "array") or (any(.aliases[]; (type != "string") or length == 0)) or
      ((.enabled | type) != "boolean") or
      ((.legacy | type) != "boolean")
    )] | length == 0)
    and (([.presets[].id] | length) == ([.presets[].id] | unique | length))
  ' "$PRESETS_FILE" >/dev/null 2>&1 || {
    CONFIG_ERROR="JSON 格式、字段、推理档位或重复 id 无效"
    return 1
  }
}

load_preset_index() {
  PRESET_IDS=()
  PRESET_GROUPS=()
  PRESET_LABEL=()
  PRESET_GROUP=()
  PRESET_MODEL=()
  PRESET_EFFORT=()
  PRESET_KEY=()

  local id label group model effort enabled legacy existing group_seen
  while IFS=$'\t' read -r id label group model effort enabled legacy; do
    [[ -n "$id" ]] || continue
    PRESET_IDS+=("$id")
    PRESET_LABEL[$id]="$label"
    PRESET_GROUP[$id]="$group"
    PRESET_MODEL[$id]="$model"
    PRESET_EFFORT[$id]="$effort"
    PRESET_KEY[$id]="$model:$effort"
    group_seen=0
    for existing in "${PRESET_GROUPS[@]}"; do
      if [[ "$existing" == "$group" ]]; then group_seen=1; break; fi
    done
    if (( ! group_seen )); then PRESET_GROUPS+=("$group"); fi
  done < <("$JQ" -r '.presets[] | select(.enabled == true) | [.id, .label, .group, .model, .effort, .enabled, .legacy] | @tsv' "$PRESETS_FILE")
}

if ! validate_presets; then
  CONFIG_VALID=0
else
  load_preset_index
fi

menu_text() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//|/／}"
  print -r -- "$value"
}

checked_if() {
  if [[ "$1" == "$2" ]]; then
    print -r -- "true"
  else
    print -r -- "false"
  fi
}

display_name() {
  local model="$1"
  local effort="$2"
  local id
  for id in "${PRESET_IDS[@]}"; do
    if [[ "${PRESET_KEY[$id]}" == "$model:$effort" ]]; then
      print -r -- "${PRESET_LABEL[$id]}"
      return
    fi
  done
  print -r -- "$model / $effort"
}

preset_state_name() {
  local state_file="$1"
  local preset label

  [[ -f "$state_file" && ! -L "$state_file" ]] || {
    print -r -- "尚未应用"
    return
  }

  preset="$("$JQ" -r '.preset // empty' "$state_file" 2>/dev/null || true)"
  if [[ -n "$preset" && -n "${PRESET_LABEL[$preset]-}" ]]; then
    print -r -- "${PRESET_LABEL[$preset]}"
  elif [[ -n "$preset" ]]; then
    print -r -- "旧预设已删除（$preset）"
  else
    print -r -- "状态不可读"
  fi
}

compatibility_name() {
  local contents compact main_status side_status
  [[ -f "$DIAGNOSTICS_FILE" && ! -L "$DIAGNOSTICS_FILE" ]] || {
    print -r -- "尚未检查"
    return
  }
  contents="$(<"$DIAGNOSTICS_FILE")"
  compact="${contents//[[:space:]]/}"
  if [[ "$compact" != *'"stage":"compatibility-check"'* ]]; then
    print -r -- "等待检查"
    return
  fi
  if [[ "$compact" == *'"main_detected":true'* ]]; then
    main_status="主线程 ✓"
  else
    main_status="主线程无法识别"
  fi
  if [[ "$compact" == *'"side_detected":true'* ]]; then
    side_status="侧栏 ✓"
  else
    side_status="侧栏未打开或无法识别"
  fi
  print -r -- "$main_status · $side_status"
}

apply_preset() {
  local preset="$1"
  local values model effort temp_file

  if (( ! CONFIG_VALID )); then
    print -u2 -- "预设配置错误：$CONFIG_ERROR"
    return 3
  fi
  values="$("$JQ" -r --arg id "$preset" \
    '.presets[] | select(.id == $id and .enabled == true) | [.model, .effort] | @tsv' \
    "$PRESETS_FILE")"
  [[ -n "$values" ]] || {
    print -u2 -- "Unknown or disabled preset: $preset"
    return 2
  }
  IFS=$'\t' read -r model effort <<< "$values"

  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || {
    print -u2 -- "Refusing to update a missing or symbolic-link config file"
    return 3
  }

  temp_file="$(/usr/bin/mktemp "$CODEX_CONFIG_DIR/config.toml.swiftbar.XXXXXX")"
  trap '/bin/rm -f -- "$temp_file"' EXIT

  /usr/bin/awk -v model="$model" -v effort="$effort" '
    BEGIN { model_count = 0; effort_count = 0 }
    /^model[[:space:]]*=/ && model_count == 0 {
      print "model = \"" model "\""
      model_count++
      next
    }
    /^model_reasoning_effort[[:space:]]*=/ && effort_count == 0 {
      print "model_reasoning_effort = \"" effort "\""
      effort_count++
      next
    }
    { print }
    END {
      if (model_count != 1 || effort_count != 1) exit 42
    }
  ' "$CONFIG_FILE" > "$temp_file"

  /bin/chmod 600 "$temp_file"
  /bin/cp -p "$CONFIG_FILE" "$BACKUP_FILE"
  /bin/mv -f "$temp_file" "$CONFIG_FILE"
  trap - EXIT
}

emit_preset_groups() {
  local mode="$1"
  local group id label
  for group in "${PRESET_GROUPS[@]}"; do
    print -r -- "$(menu_text "$group") | disabled=true size=11"
    for id in "${PRESET_IDS[@]}"; do
      [[ "${PRESET_GROUP[$id]}" == "$group" ]] || continue
      label="$(menu_text "${PRESET_LABEL[$id]}")"
      case "$mode" in
        global)
          print -r -- "$label | bash=$SCRIPT_FILE param1=global param2=$id terminal=false refresh=true checked=$(checked_if "$current_key" "${PRESET_KEY[$id]}")"
          ;;
        main)
          print -r -- "$label | bash=$HAMMERSPOON_DISPATCH_FILE param1=main param2=$id terminal=false refresh=true"
          ;;
        side)
          print -r -- "$label | bash=$HAMMERSPOON_DISPATCH_FILE param1=side param2=$id terminal=false refresh=true"
          ;;
      esac
    done
  done
}

if (( $# > 0 )); then
  case "$1" in
    global)
      (( $# == 2 )) || {
        print -u2 -- "Usage: $0 global PRESET"
        exit 2
      }
      apply_preset "$2" || exit $?
      ;;
    *)
      (( $# == 1 )) || {
        print -u2 -- "Unknown action: $*"
        exit 2
      }
      apply_preset "$1" || exit $?
      ;;
  esac
fi

current_model="$(read_setting model)"
current_effort="$(read_setting model_reasoning_effort)"
current_key="$current_model:$current_effort"
if (( CONFIG_VALID )); then
  current_name="$(display_name "$current_model" "$current_effort")"
else
  current_name="$current_model / $current_effort"
fi

print -r -- "Codex: $current_name"
print -r -- "---"

if (( ! CONFIG_VALID )); then
  print -r -- "预设配置错误 | color=red disabled=true"
  print -r -- "$CONFIG_ERROR | disabled=true size=11"
else
  main_name="$(preset_state_name "$MAIN_STATE_FILE")"
  side_name="$(preset_state_name "$SIDE_STATE_FILE")"
  compatibility_status="$(compatibility_name)"

  print -r -- "新任务默认配置（当前主线程同步目标） | disabled=true"
  emit_preset_groups global
  print -r -- "---"
  print -r -- "当前主线程（切换后同步新任务） | disabled=true"
  print -r -- "最近成功：$main_name | disabled=true size=11"
  emit_preset_groups main
  print -r -- "---"
  print -r -- "当前侧栏 | disabled=true"
  print -r -- "最近成功：$side_name | disabled=true size=11"
  emit_preset_groups side
  print -r -- "打开侧栏并应用最近预设 | bash=$HAMMERSPOON_DISPATCH_FILE param1=side-open terminal=false refresh=true"
  print -r -- "---"
  print -r -- "检查 Codex 控件兼容性 | bash=$HAMMERSPOON_DISPATCH_FILE param1=check terminal=false refresh=true"
  print -r -- "兼容性：$compatibility_status | disabled=true size=11"
fi

print -r -- "---"
print -r -- "打开/编辑预设配置（让 AI 修改此文件） | bash=/usr/bin/open param1=-a param2=TextEdit param3=$PRESETS_FILE terminal=false"
print -r -- "重新加载预设配置 | bash=$HAMMERSPOON_DISPATCH_FILE param1=reload terminal=false refresh=true"
print -r -- "共享默认：$current_name（主线程与新任务） | disabled=true size=11"
print -r -- "Open config.toml | bash=/usr/bin/open param1=-a param2=TextEdit param3=$CONFIG_FILE terminal=false"
