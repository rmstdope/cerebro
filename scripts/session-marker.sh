# scripts/session-marker.sh - the one bash spelling of cerebro's marker sentence.
#
# SOURCED, NEVER EXECUTED. Like scripts/root-hints.sh beside it, it has no `set -euo pipefail' of
# its own and defines functions only, so sourcing it changes nothing about the caller's shell but
# the names it can call. Builtins alone (`printf'), because tests/launchers.sh runs the launch path
# with a PATH holding `dirname' and `bash' and nothing else.
#
# THE SENTENCE. `scripts/launch' opens every session's prompt with:
#
#     This session is <Name> of the cerebro fleet rooted at <root>/. This sentence is how the fleet
#     view proves the session belongs to this checkout; do not remove it.
#
# It is the WHOLE of the liveness rule since cb-d59.3 - the prompt is the one argv slot every agent
# CLI accepts, so neither half of the rule contains a provider's flag spelling. Two needles are cut
# from it: the name, and the root (cb-lzi), because a name is unique inside one consumer and not on
# the machine.
#
# WHY IT EXISTS (cb-9su). One sentence was written in one place and parsed in four, each in its own
# language and each with its own hand-tuned subtleties. The same class of defect - two readers of one
# sentence disagreeing about it - was fixed three times: 7bd5962 and 9420ff2 between the bash and
# elisp copies, and 94bef94/cb-akt in `scripts/fleet-cost', whose SQL prefilter asked whether the
# field BEGINS WITH the marker where its siblings ask whether it APPEARS IN it, dropped every row
# carrying anything before it, and reported a silent zero for a fleet that had spent ten thousand
# credits that week. This library removes the writer/reader pair from that count: `scripts/launch'
# and `scripts/agent-alive' now obtain the text here rather than each carrying it. The elisp and
# SQL/jq copies stay copies - `emacs/cerebro.el' cannot source a bash library (the qualification
# `cerebro--log-line' already carries against `scripts/jsonl-log.sh'), and the prefilter runs inside
# SQLite - but since cb-9su a copy cannot exist UNDECLARED: `scripts/marker-readers' fails the gate
# on any file in this repository that spells the sentence without being a declared reader with a
# named subscribing suite.
#
# THREE PROPERTIES ARE LOAD-BEARING, each already paid for elsewhere:
#
#   - The name needle ends at the space after "rooted at ". That is what keeps one roster name that
#     is a prefix of another (Cyclops / Cyclopsly) from silently reading as alive - the job the
#     elisp `\_>' word boundary used to do on `--name'.
#   - The root needle carries exactly ONE trailing slash, normalised with `${1%/}/', so `/repos/x'
#     does not match a sibling `/repos/x-hud' whether or not the caller's root ever grows a slash of
#     its own.
#   - The sentence carries NO APOSTROPHE, for `scripts/launch''s own bash-3.2 reason and because
#     tests/fleet-cost.sh interpolates the field into a `sqlite3' string literal.
#
# EACH FUNCTION ECHOES rather than assigning an out-variable. An out-variable would save two forks
# per `agent-alive' call, which already forks `jq', `ps' and possibly `consumer-root'; consistency
# with `scripts/root-hints.sh', the library this one sits beside, is worth more than two forks.
# Its cases are tests/session-marker.sh, and the readers' shared cases are
# tests/lib/session-args.cases - add a case there, not in one suite.

# The whole sentence, as `scripts/launch' writes it.
#   $1 = agent name
#   $2 = consumer root, with or without a trailing slash
cerebro_marker_sentence() {
  printf '%s' "This session is $1 of the cerebro fleet rooted at ${2%/}/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."
}

# The name needle: the sentence's opening, up to and INCLUDING the space after "rooted at".
#   $1 = agent name
cerebro_marker_name_needle() {
  printf '%s' "This session is $1 of the cerebro fleet rooted at "
}

# The root needle: the second half, with exactly one trailing slash.
#   $1 = consumer root, with or without a trailing slash
cerebro_marker_root_needle() {
  printf '%s' "cerebro fleet rooted at ${1%/}/"
}

# The name- and root-independent fragment, for anything asking only whether a text carries a marker
# at all. `scripts/marker-readers' greps for this, which is why that check is not itself a reader of
# the sentence: the one bash spelling is here, and everything in bash that needs the text asks.
cerebro_marker_infix() {
  printf '%s' "cerebro fleet rooted at"
}
