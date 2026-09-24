#!/bin/zsh

# Dispatch SwiftBar actions through Hammerspoon's IPC CLI. This avoids relying
# on LaunchServices having the hammerspoon:// URL scheme registered.

set -eu

readonly ACTION="${1:-}"
readonly PRESET="${2:-}"

find_hammerspoon_cli() {
  local candidate
  if [[ -n "${CODEX_HAMMERSPOON_CLI:-}" && -x "$CODEX_HAMMERSPOON_CLI" ]]; then
    print -r -- "$CODEX_HAMMERSPOON_CLI"
    return 0
  fi
  for candidate in /opt/homebrew/bin/hs /usr/local/bin/hs; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

case "$ACTION" in
  main)
    readonly EVENT="codex-main-preset"
    ;;
  side)
    readonly EVENT="codex-side-preset"
    ;;
  side-open)
    readonly EVENT="codex-side-open"
    ;;
  check)
    readonly EVENT="codex-preset-check"
    ;;
  reload)
    readonly EVENT="codex-preset-reload"
    ;;
  *)
    print -u2 -- "Unknown Hammerspoon action: $ACTION"
    exit 2
    ;;
esac

readonly HS_CLI="$(find_hammerspoon_cli || true)"
[[ -n "$HS_CLI" ]] || {
  print -u2 -- "Hammerspoon CLI not found; install Hammerspoon CLI or set CODEX_HAMMERSPOON_CLI"
  exit 127
}

if [[ -n "$PRESET" ]]; then
  # Preset ids are validated by the SwiftBar/Hammerspoon loaders as well as by
  # this restricted shell argument. No user-entered text is evaluated as Lua.
  [[ "$PRESET" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || {
    print -u2 -- "Invalid preset id"
    exit 2
  }
  readonly LUA="codexPresetDispatch(\"$EVENT\", \"$PRESET\")"
else
  readonly LUA="codexPresetDispatch(\"$EVENT\")"
fi

exec "$HS_CLI" -q -A -c "$LUA"
