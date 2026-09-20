#!/bin/zsh

# <swiftbar.title>Codex Model Presets</swiftbar.title>
# <swiftbar.version>v1.5.0</swiftbar.version>
# <swiftbar.desc>Switch new-task defaults or the current Codex main/side composer preset.</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

set -eu

readonly CODEX_CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
readonly CONFIG_FILE="$CODEX_CONFIG_DIR/config.toml"
readonly BACKUP_FILE="$CODEX_CONFIG_DIR/config.toml.swiftbar-backup"
readonly MAIN_STATE_FILE="$CODEX_CONFIG_DIR/codex-main-preset-state.json"
readonly SIDE_STATE_FILE="$CODEX_CONFIG_DIR/codex-side-preset-state.json"
readonly DIAGNOSTICS_FILE="$CODEX_CONFIG_DIR/codex-preset-diagnostics/latest.json"
readonly SCRIPT_FILE="${0:A}"

read_setting() {
  /usr/bin/awk -F '"' -v key="$1" \
    '$0 ~ "^" key "[[:space:]]*=" { print $2; exit }' "$CONFIG_FILE"
}

preset_values() {
  case "$1" in
    luna-max)   print -r -- "gpt-5.6-luna max" ;;
    terra-high) print -r -- "gpt-5.6-terra high" ;;
    sol-medium) print -r -- "gpt-5.6-sol medium" ;;
    sol-high)   print -r -- "gpt-5.6-sol high" ;;
    *) return 2 ;;
  esac
}

apply_preset() {
  local preset="$1"
  local values model effort temp_file

  values="$(preset_values "$preset")" || {
    print -u2 -- "Unknown preset: $preset"
    return 2
  }
  model="${values%% *}"
  effort="${values##* }"

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

display_name() {
  case "$1:$2" in
    gpt-5.6-luna:max)   print -r -- "Luna Max" ;;
    gpt-5.6-terra:high) print -r -- "Terra High" ;;
    gpt-5.6-sol:medium) print -r -- "Sol Medium" ;;
    gpt-5.6-sol:high)   print -r -- "Sol High" ;;
    *)                  print -r -- "$1 / $2" ;;
  esac
}

checked_if() {
  if [[ "$1" == "$2" ]]; then
    print -r -- "true"
  else
    print -r -- "false"
  fi
}

preset_state_name() {
  local state_file="$1"
  local contents preset

  [[ -f "$state_file" && ! -L "$state_file" ]] || {
    print -r -- "尚未应用"
    return
  }

  contents="$(<"$state_file")"
  if [[ "$contents" =~ '"preset"[[:space:]]*:[[:space:]]*"([^"]+)"' ]]; then
    preset="${match[1]}"
    case "$preset" in
      luna-max)   print -r -- "Luna Max" ;;
      terra-high) print -r -- "Terra High" ;;
      sol-medium) print -r -- "Sol Medium" ;;
      sol-high)   print -r -- "Sol High" ;;
      *)          print -r -- "未知预设" ;;
    esac
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

if (( $# > 0 )); then
  case "$1" in
    global)
      (( $# == 2 )) || {
        print -u2 -- "Usage: $0 global PRESET"
        exit 2
      }
      apply_preset "$2"
      ;;
    luna-max|terra-high|sol-medium|sol-high)
      # Backward compatibility with existing SwiftBar menu invocations.
      apply_preset "$1"
      ;;
    *)
      print -u2 -- "Unknown action: $1"
      exit 2
      ;;
  esac
fi

current_model="$(read_setting model)"
current_effort="$(read_setting model_reasoning_effort)"
current_key="$current_model:$current_effort"
current_name="$(display_name "$current_model" "$current_effort")"
main_name="$(preset_state_name "$MAIN_STATE_FILE")"
side_name="$(preset_state_name "$SIDE_STATE_FILE")"
compatibility_status="$(compatibility_name)"

print -r -- "Codex: $current_name"
print -r -- "---"
print -r -- "新任务默认配置 | disabled=true"
print -r -- "Luna Max | bash=$SCRIPT_FILE param1=global param2=luna-max terminal=false refresh=true checked=$(checked_if "$current_key" 'gpt-5.6-luna:max')"
print -r -- "Terra High | bash=$SCRIPT_FILE param1=global param2=terra-high terminal=false refresh=true checked=$(checked_if "$current_key" 'gpt-5.6-terra:high')"
print -r -- "Sol Medium | bash=$SCRIPT_FILE param1=global param2=sol-medium terminal=false refresh=true checked=$(checked_if "$current_key" 'gpt-5.6-sol:medium')"
print -r -- "Sol High | bash=$SCRIPT_FILE param1=global param2=sol-high terminal=false refresh=true checked=$(checked_if "$current_key" 'gpt-5.6-sol:high')"
print -r -- "---"
print -r -- "当前主线程 | disabled=true"
print -r -- "最近成功：$main_name | disabled=true size=11"
print -r -- "Luna Max | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-main-preset?preset=luna-max terminal=false refresh=true"
print -r -- "Terra High | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-main-preset?preset=terra-high terminal=false refresh=true"
print -r -- "Sol Medium | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-main-preset?preset=sol-medium terminal=false refresh=true"
print -r -- "Sol High | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-main-preset?preset=sol-high terminal=false refresh=true"
print -r -- "---"
print -r -- "当前侧栏 | disabled=true"
print -r -- "最近成功：$side_name | disabled=true size=11"
print -r -- "Luna Max | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-side-preset?preset=luna-max terminal=false refresh=true"
print -r -- "Terra High | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-side-preset?preset=terra-high terminal=false refresh=true"
print -r -- "Sol Medium | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-side-preset?preset=sol-medium terminal=false refresh=true"
print -r -- "Sol High | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-side-preset?preset=sol-high terminal=false refresh=true"
print -r -- "打开侧栏并应用最近预设 | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-side-open terminal=false refresh=true"
print -r -- "---"
print -r -- "检查 Codex 控件兼容性 | bash=/usr/bin/open param1=-g param2=hammerspoon://codex-preset-check terminal=false refresh=true"
print -r -- "兼容性：$compatibility_status | disabled=true size=11"
print -r -- "---"
print -r -- "全局配置：$current_name（仅新任务） | disabled=true size=11"
print -r -- "Open config.toml | bash=/usr/bin/open param1=-a param2=TextEdit param3=$CONFIG_FILE terminal=false"
