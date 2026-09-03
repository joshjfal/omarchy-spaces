#!/bin/bash -p
# Spaces plugin installer.
#
# Adds a marked loader block to ~/.config/hypr/bindings.lua that dofile()s the
# plugin's bindings.lua, backs the file up first, reloads Hyprland, and rolls
# the change back if the new configuration does not validate. Also registers
# the overlay with the Omarchy shell.
#
# Usage: install.sh [--yes]

PATH=/usr/bin:/bin
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_ORIGIN_PATH LD_DEBUG LD_DEBUG_OUTPUT
unset CDPATH BASH_ENV ENV
IFS=$' \t\n'
set -euo pipefail

plugin_id="joshj.spaces"
begin_marker="-- >>> ${plugin_id} bindings >>>"
end_marker="-- <<< ${plugin_id} bindings <<<"
assume_yes=0

case "${BASH_SOURCE[0]}" in
  */*) script_dir_raw="${BASH_SOURCE[0]%/*}" ;;
  *)   script_dir_raw="." ;;
esac
script_dir=$(cd -- "$script_dir_raw" && pwd -P)

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"

jq_bin=/usr/bin/jq
gum_bin=/usr/bin/gum
hyprctl_bin=/usr/bin/hyprctl

fail() { printf 'spaces install: %s\n' "$*" >&2; exit 1; }

confirm() {
  (( assume_yes )) && return 0
  [[ -t 0 && -t 1 ]] || fail "confirmation required; rerun with --yes"
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

[[ -f "$script_dir/manifest.json" ]] || fail "manifest.json missing beside this script"
[[ $("$jq_bin" -r '.id // empty' "$script_dir/manifest.json") == "$plugin_id" ]] \
  || fail "this script is not inside the $plugin_id plugin"
[[ -d "$hypr_dir" ]] || fail "Hyprland config directory not found: $hypr_dir"
[[ -f "$bindings_file" ]] || fail "not found: $bindings_file"

for s in space-switch space-move space-cycle space-snapshot; do
  chmod +x "$script_dir/scripts/$s" 2>/dev/null || true
done

if grep -qF "$begin_marker" "$bindings_file"; then
  printf 'Spaces bindings already present in %s.\n' "$bindings_file"
else
  printf 'This adds Spaces bindings to %s (a timestamped backup is kept):\n' "$bindings_file"
  printf '  SUPER+1-0 / SHIFT+1-0  -> switch / move-window to a space (all monitors)\n'
  printf '  SUPER+CTRL+LEFT/RIGHT  -> previous / next space\n'
  printf '  SUPER+CTRL+DOWN        -> the Spaces overlay\n'
  printf 'SUPER+CTRL+LEFT/RIGHT replaces Omarchy'\''s grouped-window focus binding.\n'
  confirm "Install the Spaces bindings?" || fail "cancelled"

  backup="${bindings_file}.bak.$(date +%s)"
  cp -p -- "$bindings_file" "$backup"

  tmp=$(mktemp -- "${bindings_file}.XXXXXX")
  {
    cat -- "$bindings_file"
    printf '\n%s\n' "$begin_marker"
    printf '-- Spaces plugin. Optional config with hl.env() BEFORE this block:\n'
    printf '--   hl.env("SPACES_PRIMARY", "DP-1")  -- monitor holding workspaces 1..OFFSET\n'
    printf '--   hl.env("SPACES_OFFSET", "10")     -- per-monitor workspace-id offset\n'
    printf '--   hl.env("SPACES_COUNT", "5")       -- how many spaces prev/next steps through\n'
    printf 'do\n'
    printf '  local p = os.getenv("HOME") .. "/.config/omarchy/plugins/%s/bindings.lua"\n' "$plugin_id"
    printf '  local f = io.open(p, "r")\n'
    printf '  if f then f:close(); dofile(p) end\n'
    printf 'end\n'
    printf '%s\n' "$end_marker"
  } > "$tmp"
  chmod --reference="$bindings_file" -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$bindings_file"

  if [[ -x $hyprctl_bin ]] && "$hyprctl_bin" reload >/dev/null 2>&1; then
    errors=$("$hyprctl_bin" configerrors 2>/dev/null || true)
    if [[ -n $errors && $errors != "no errors" && $errors != "[]" ]]; then
      cp -p -- "$backup" "$bindings_file"
      "$hyprctl_bin" reload >/dev/null 2>&1 || true
      fail "Hyprland reported config errors; reverted. Backup kept at $backup"
    fi
  fi
  printf 'Spaces bindings installed. Backup: %s\n' "$backup"
fi

# Register the overlay with the running shell so the overlay can be summoned.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi
if command -v omarchy >/dev/null 2>&1; then
  if omarchy plugin enable "$plugin_id" >/dev/null 2>&1; then
    printf 'Enabled %s in the Omarchy shell.\n' "$plugin_id"
  else
    printf 'Could not auto-enable; run: omarchy plugin enable %s\n' "$plugin_id"
  fi
fi

printf 'Done. Press SUPER+CTRL+DOWN for the Spaces overlay.\n'
