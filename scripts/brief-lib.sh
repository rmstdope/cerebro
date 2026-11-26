# Sourced, never run: what the startup briefs share - `scripts/ux-brief' (cb-9tnf) and
# `scripts/producer-brief' (cb-pe3y). `scripts/launch' runs one of them before the agent CLI is
# exec'd and puts what it prints in the opening prompt.
#
#     source "$script_dir/brief-lib.sh"

# brief_bounded <seconds> <command> [args...]: run it with its output discarded, killed at the bound
# (status 124). A brief runs inside `launch', before the session's pane shows anything, so a hung
# remote has to read as a failed command rather than a blank row.
brief_bounded() {
  local secs="$1" child ticks=0
  shift
  "$@" >/dev/null 2>&1 &
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    if [[ $ticks -ge $((secs * 5)) ]]; then
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$child"
}

# brief_bead <root> <id>: the bead's JSON object. 1 when `bd show' fails (its own stderr passed
# through) or prints nothing readable, with nothing on stdout - never an empty bead.
brief_bead() {
  local root="$1" id="$2" caller="${0##*/}" shown
  shown="$(bd -C "$root" show "$id" --json)" || return 1
  if ! printf '%s' "$shown" | jq -e '(if type=="array" then .[0] else . end) | objects' 2>/dev/null; then
    echo "$caller: bd show $id did not print JSON this script can read" >&2
    return 1
  fi
}

# brief_field <bead json> <key>: the value as text, a list joined with ", ", empty when absent.
brief_field() {
  jq -r --arg k "$2" '.[$k] // "" | if type=="array" then join(", ") else tostring end' <<<"$1"
}

# Free text, quoted: every line behind `> ', so a heading in a bead's notes cannot pass for one of
# the brief's own, and the whole reads as data rather than as part of the instruction.
brief_quoted() {
  if [[ -n "$1" ]]; then printf '%s\n' "$1" | sed 's/^/> /'; else printf '(none)\n'; fi
}
