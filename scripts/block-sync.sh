#!/usr/bin/env bash
#
# block-sync.sh - the one place this repository answers "does every carrier's marked copy of a
# canonical block match the canonical file". SOURCED, never executed.
#
# A rule that must be read where it applies gets written out once per carrier, and then it drifts:
# cb-m7u paid for that with the Four Eye Principle (two copies, already disagreeing when the bead
# was filed) and cb-mqa with the state-file contract (seven copies, the same sentence fixed in one
# file and re-fixed across five more three days later). Both answers are the same mechanism - a
# canonical file, a marked verbatim copy in each carrier, a gate predicate that fails on drift - so
# the mechanism lives here and each predicate keeps only its own header, carrier list and exit
# codes.
#
#   cerebro_block_sync <marker-word> <canonical-path> <carrier>...
#
#     Paths are relative to the CALLER's current directory; the caller has already cd'd to its root.
#     Findings on stdout, one per line, in the order the carriers were given:
#       missing: <canonical> (the canonical block)      - and nothing else is printed
#       missing: <carrier> (carrier file not found)
#       unmarked: <carrier> (no <marker-word>:begin/end pair)
#       drifted: <carrier> (block differs from <canonical>)
#     Returns 0 when every carrier agrees, 1 when there is at least one finding.
#
#   cerebro_block_strip_blanks <text>
#
#     Leading and trailing EMPTY lines removed; a line of spaces is not an empty line.
#
# It RETURNS, never exits: its callers own their exit codes, and a `return' cannot end the script
# that sourced it.
#
# NO `set -e', and it must not rely on one. Its callers run under `set -uo pipefail' and not `-e' on
# purpose - the answer IS the exit status, and a failed comparison inside the carrier loop must
# print its finding rather than end the script (`.cerebro/traps.md', "An advisory step can eat the
# exit status that follows it"). For the same reason no loop body here ends in `cmd1 && cmd2', which
# would make the loop's status depend on its last iteration.
#
# Builtins only, in the house style of `scripts/root-hints.sh', `scripts/session-marker.sh' and
# `scripts/jsonl-log.sh': a library a launcher may source must not need a PATH.

# Leading and trailing EMPTY lines removed, and nothing else.
#
# `$(<file)' strips trailing newlines but not leading blank lines, and the markers are surrounded by
# blank lines on purpose: CommonMark ends an HTML block at a blank line, so a marker immediately
# followed by prose swallows that prose into the comment. Both sides have their leading and trailing
# EMPTY lines stripped, so those load-bearing blanks are never drift. A line of spaces is not an
# empty line and is drift, deliberately: the comparison is otherwise byte-exact, and an invisible
# difference that the checker forgives is one no reader can see either.
cerebro_block_strip_blanks() {
  local s="$1"
  while [[ $s == $'\n'* ]]; do s="${s#$'\n'}"; done
  while [[ $s == *$'\n' ]]; do s="${s%$'\n'}"; done
  printf '%s' "$s"
}

cerebro_block_sync() {
  local marker="$1"
  local canonical_path="$2"
  shift 2

  # Without the canonical block there is nothing to compare against, and every carrier would report
  # `drifted:' as well - burying the one real fault.
  if [[ ! -f "$canonical_path" ]]; then
    echo "missing: $canonical_path (the canonical block)"
    return 1
  fi

  local canonical
  canonical="$(cerebro_block_strip_blanks "$(<"$canonical_path")")"

  local findings=0
  local carrier line trimmed block inside begins ends out_of_order

  for carrier in "$@"; do
    # Its own line rather than `unmarked:': a carrier that is gone has no markers to have lost, and
    # saying it does sends a reader to grep a file that is not there.
    if [[ ! -f "$carrier" ]]; then
      echo "missing: $carrier (carrier file not found)"
      findings=1
      continue
    fi

    # Markers are matched on the whole trimmed line, so a mention of one inside prose is not one.
    # Zero of either, more than one of either, or an end before a begin: there is no block to
    # compare.
    block=""
    inside=0
    begins=0
    ends=0
    out_of_order=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      if [[ "$trimmed" == "<!-- $marker:begin -->" ]]; then
        begins=$((begins + 1))
        inside=1
        continue
      fi
      if [[ "$trimmed" == "<!-- $marker:end -->" ]]; then
        ends=$((ends + 1))
        [[ $inside -eq 1 ]] || out_of_order=1   # an end before any begin: never a usable pair
        inside=0
        continue
      fi
      if [[ $inside -eq 1 ]]; then
        block+="$line"$'\n'
      fi
    done <"$carrier"

    if [[ $begins -ne 1 || $ends -ne 1 || $out_of_order -eq 1 ]]; then
      echo "unmarked: $carrier (no $marker:begin/end pair)"
      findings=1
      continue
    fi

    if [[ "$(cerebro_block_strip_blanks "$block")" != "$canonical" ]]; then
      echo "drifted: $carrier (block differs from $canonical_path)"
      findings=1
    fi
  done

  return "$findings"
}
