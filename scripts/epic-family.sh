# Sourced, never run: the children of a bead that are members of its epic family.
#
#     source "$script_dir/epic-family.sh"
#     children="$(epic_family_children "$root" "$id")" || exit 1
#
# Prints the JSON array `bd children <id> --json` returns, with the `event` beads dropped:
# `bd set-state` files its audit record as an event under the bead it changed, with a dotted
# child id, and an event is never a member of a family. That rule is tests/lib/epic-family.json,
# which every implementation answers. A failed or non-JSON read returns 1 with the reason on
# stderr, never an empty family.

epic_family_children() {
  local root="$1" id="$2" caller="${0##*/}" children
  if ! children="$(bd -C "$root" children "$id" --json)"; then
    echo "$caller: bd children failed for $id" >&2
    return 1
  fi
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$children"; then
    echo "$caller: bd children printed something that is not JSON for $id" >&2
    return 1
  fi
  jq -c '[.[] | select(.issue_type != "event")]' <<<"$children"
}
