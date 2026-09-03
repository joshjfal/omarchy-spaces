#!/bin/bash -p
# Spaces plugin uninstaller: removes the marked loader block from
# ~/.config/hypr/bindings.lua (keeping a timestamped backup), reloads Hyprland,
# and unregisters the overlay from the Omarchy shell. The plugin files are left
# in place - delete the directory to remove them.
#
# Usage: uninstall.sh [--yes]

PATH=/usr/bin:/bin
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_ORIGIN_PATH LD_DEBUG LD_DEBUG_OUTPUT
unset CDPATH BASH_ENV ENV
IFS=$' \t\n'
set -euo pipefail

plugin_id="joshj.spaces"
begin_marker="-- >>> ${plugin_id} bindings >>>"
end_marker="-- <<< ${plugin_id} bindings <<<"
assume_yes=0

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
bindings_file="$config_home/hypr/bindings.lua"
hyprctl_bin=/usr/bin/hyprctl
gum_bin=/usr/bin/gum

fail() { printf 'spaces uninstall: %s\n' "$*" >&2; exit 1; }

confirm() {
  (( assume_yes )) && return 0
  [[ -t 0 && -t 1 ]] || return 0
  if [[ -x $gum_bin ]]; then "$gum_bin" confirm "$1"; return; fi
  local answer; read -r -p "$1 [y/N] " answer
  [[ $answer == [Yy] || $answer == [Yy][Ee][Ss] ]]
}

while (( $# > 0 )); do
  case "$1" in
    --yes|-y) assume_yes=1 ;;
    -h|--help) printf 'Usage: %s [--yes]\n' "$0"; exit 0 ;;
    *) fail "unknown option '$1'" ;;
  esac
  shift
done

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
fi

if [[ -f "$bindings_file" ]] && grep -qF "$begin_marker" "$bindings_file"; then
  confirm "Remove the Spaces binding block from $bindings_file?" || fail "cancelled"

  backup="${bindings_file}.bak.$(date +%s)"
  cp -p -- "$bindings_file" "$backup"

  tmp=$(mktemp -- "${bindings_file}.XXXXXX")
  # Strip the marked block, then collapse any trailing blank lines it left.
  printf '%s\n' "$(awk -v b="$begin_marker" -v e="$end_marker" '
    index($0, b) { skip = 1 }
    !skip        { print }
    index($0, e) { skip = 0 }
  ' "$bindings_file")" > "$tmp"

  chmod --reference="$bindings_file" -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$bindings_file"
  [[ -x $hyprctl_bin ]] && "$hyprctl_bin" reload >/dev/null 2>&1 || true
  printf 'Removed Spaces bindings. Backup: %s\n' "$backup"
else
  printf 'No Spaces binding block found in %s.\n' "$bindings_file"
fi

printf 'Plugin files remain at ~/.config/omarchy/plugins/%s\n' "$plugin_id"
printf 'Remove them with: omarchy plugin remove %s\n' "$plugin_id"
