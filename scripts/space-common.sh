#!/usr/bin/env bash
# Shared helpers for the Spaces scripts. Sourced, not executed.
#
# A "space" N puts workspace N + i*OFFSET on the i-th monitor, where i=0 is the
# primary. Every connected monitor flips together. Works with 1..n monitors and
# any physical arrangement.
#
# Config (environment):
#   SPACES_PRIMARY   primary monitor name (hyprctl monitors). Default: the
#                    largest connected monitor (ties: the one hyprctl lists
#                    first).
#   SPACES_OFFSET    per-monitor workspace-id offset. Default: 10.
#   SPACES_COUNT     how many spaces to step through / show. Default: 5.

SPACES_OFFSET="${SPACES_OFFSET:-10}"
[[ "$SPACES_OFFSET" =~ ^[0-9]+$ ]] && (( SPACES_OFFSET >= 1 )) || SPACES_OFFSET=10

SPACES_COUNT="${SPACES_COUNT:-5}"
[[ "$SPACES_COUNT" =~ ^[0-9]+$ ]] && (( SPACES_COUNT >= 1 )) || SPACES_COUNT=5
(( SPACES_COUNT > SPACES_OFFSET )) && SPACES_COUNT=$SPACES_OFFSET

# True if $1 is a usable space number (1..OFFSET).
space_is_valid_n() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= SPACES_OFFSET )); }

# Populates the global array SPACE_MONITORS with monitor names in assignment
# order: primary first, then the rest ordered by physical position (x, then y).
# Index in this array is the monitor's offset multiplier.
space_load_monitors() {
  local mon_json want="${SPACES_PRIMARY:-}"
  mon_json="$(hyprctl monitors -j)" || return 1

  # names ordered by physical position (left-to-right, then top-to-bottom)
  local by_pos
  mapfile -t by_pos < <(
    jq -r '.[] | "\(.x)\t\(.y)\t\(.name)"' <<<"$mon_json" \
      | sort -n -k1,1 -k2,2 | cut -f3-
  )
  (( ${#by_pos[@]} )) || return 1

  # primary: the env name if it is actually connected, otherwise the largest
  # monitor by pixel area (hyprctl order breaks ties via the stable sort).
  local primary=""
  if [[ -n "$want" ]]; then
    local n
    for n in "${by_pos[@]}"; do [[ "$n" == "$want" ]] && primary="$want" && break; done
  fi
  if [[ -z "$primary" ]]; then
    primary="$(jq -r '
      [ .[] | { name, area: (.width * .height) } ]
      | sort_by(-.area) | .[0].name
    ' <<<"$mon_json")"
  fi
  [[ -z "$primary" || "$primary" == "null" ]] && primary="${by_pos[0]}"

  SPACE_MONITORS=("$primary")
  local n
  for n in "${by_pos[@]}"; do
    if [[ "$n" != "$primary" ]]; then SPACE_MONITORS+=("$n"); fi
  done
  return 0
}

# space_workspace_for <space-number> <monitor-index>
space_workspace_for() { echo $(( $1 + $2 * SPACES_OFFSET )); }

# Fold any workspace id back to its space number (1..OFFSET).
space_fold() {
  local id="$1"
  (( id > SPACES_OFFSET )) && id=$(( (id - 1) % SPACES_OFFSET + 1 ))
  echo "$id"
}

# Index of a monitor name within SPACE_MONITORS (echoes nothing if not found).
space_monitor_index() {
  local target="$1" i
  for i in "${!SPACE_MONITORS[@]}"; do
    [[ "${SPACE_MONITORS[$i]}" == "$target" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# Echo the space currently shown on the primary monitor (folded to 1..OFFSET).
# Needs space_load_monitors to have run.
space_current() {
  local id
  id="$(hyprctl monitors -j | jq -r --arg p "${SPACE_MONITORS[0]:-}" \
    '.[] | select(.name == $p) | .activeWorkspace.id')"
  [[ -z "$id" || "$id" == "null" ]] && id="$(hyprctl activeworkspace -j | jq -r '.id')"
  space_fold "${id:-1}"
}

# Sanitize a monitor name for use in a filename.
space_sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Echo a stable key describing the apps on a workspace: sorted, unique,
# lowercased window classes joined by "_", non-alphanumerics folded to ".",
# capped at 64 chars. Empty when the workspace has no windows. The overlay
# computes the identical key and only trusts a screenshot whose filename
# carries the matching key (LC_ALL=C keeps the sort byte-ordered to match JS).
#
# Usage: space_apps_key <workspace-id>
space_apps_key() {
  hyprctl clients -j \
    | jq -r --argjson w "$1" '.[] | select(.workspace.id == $w) | .class // empty' \
    | tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sort -u \
    | paste -sd '_' - \
    | tr -c 'A-Za-z0-9_\n' '.' \
    | cut -c1-64
}
