# The parser and the graph behind `retro-sightings' - see that script's header for why this exists
# and why it is awk. Read as: one pass over every retrospective collecting `Seen before' citations
# as EDGES, then union-find over them, then one line per component of `threshold' beads or more.
#
# Variables in: threshold, prefix, dismissed (space-padded), dismiss_target, new_count.

# `s' in a field of `width', on the left when `right' is set. See the report loop for why this is
# not printf's `%*s'.
function pad(s, width, right,   out) {
  out = ""
  while (length(s) + length(out) < width) out = out " "
  return right ? out s : s out
}

function trim(s) {
  gsub(/^[ \t]+|[ \t\r]+$/, "", s)
  return s
}

# The bead a retrospective file belongs to. Not every file is `<id>.md': `ah-wxk.1-verifier.md' is
# `<bead id>-<role>.md', so the id is what the pattern matches at the FRONT rather than the stem.
function bead_of(path,   n, parts, base) {
  n = split(path, parts, "/")
  base = parts[n]
  if (match(base, "^" prefix "-[a-z0-9]+(\\.[0-9]+)?")) return substr(base, RSTART, RLENGTH)
  return ""
}

function find(id,   root, walk, next_up) {
  root = (id in parent) ? parent[id] : id
  parent[id] = root
  while (root != parent[root]) root = parent[root]
  walk = id
  while (walk != root) { next_up = parent[walk]; parent[walk] = root; walk = next_up }
  return root
}

function union(a, b) {
  parent[find(a)] = find(b)
}

function note(id) {
  if (!(id in parent)) parent[id] = id
}

# One `Seen before' paragraph, reduced to the edges it declares.
#
# A paragraph opening `None found' cites NOTHING, whatever ids appear later in it: nine files in the
# real corpus name ids there as explicit counter-examples, and reading those as citations records
# the opposite of what was written - and silently merges unrelated components, which is invisible in
# the output rather than a failure.
function flush(   body, rest, id) {
  if (!in_para) return
  in_para = 0
  if (para_bead == "") return

  body = para
  sub(/^\*\*Seen before\.\*\*[ \t]?/, "", body)
  body = trim(body)
  rest = tolower(body)
  if (rest ~ /^(none|nothing)([^a-z0-9]|$)/) return

  while (match(body, prefix "-[a-z0-9]+(\\.[0-9]+)?")) {
    id = substr(body, RSTART, RLENGTH)
    body = substr(body, RSTART + RLENGTH)
    if (id == para_bead) continue
    note(id); note(para_bead)
    union(para_bead, id)
  }
}

FNR == 1 {
  flush()
  bead = bead_of(FILENAME)
  if (bead != "") note(bead)
}

{
  line = $0
  sub(/\r$/, "", line)

  if (in_para && (trim(line) == "" || line ~ /^\*\*[^*]+\.?\*\*/ || line ~ /^##/)) flush()
  if (bead == "") next

  if (!(bead in headline) && line ~ /^##[ \t]+/) {
    headline[bead] = trim(substr(line, 3))
  }
  if (!(bead in seen_date) && line ~ /^-[ \t]+\*\*Date:\*\*/) {
    seen_date[bead] = trim(substr(line, index(line, "**Date:**") + 9))
  }

  if (line ~ /^\*\*Seen before\.\*\*/) {
    in_para = 1
    para = line
    para_bead = bead
  } else if (in_para) {
    para = para "\n" line
  }
}

END {
  flush()

  for (id in parent) {
    root = find(id)
    if (root in members) members[root] = members[root] " " id
    else members[root] = id
    size[root]++
  }

  count = 0
  for (root in members) {
    if (size[root] < threshold) continue
    n = split(members[root], ids, " ")
    # Sorted, so a finding's ids read the same from one sweep to the next.
    for (i = 2; i <= n; i++) {
      hold = ids[i]
      for (j = i - 1; j >= 1 && ids[j] > hold; j--) ids[j + 1] = ids[j]
      ids[j + 1] = hold
    }

    joined = ""
    name_bead = ""; name_text = ""; name_key = ""
    last_bead = ""; last_date = ""; last_key = ""
    for (i = 1; i <= n; i++) {
      id = ids[i]
      joined = (joined == "") ? id : joined ", " id
      # Ties on the date - and there are many, since a bad day produces several - break on bead id,
      # so the name of a finding is stable from one sweep to the next.
      if (id in headline || id in seen_date) {
        key = ((id in seen_date) ? seen_date[id] : "") "|" id
        if (id in headline && (name_key == "" || key < name_key)) {
          name_key = key; name_bead = id; name_text = headline[id]
        }
        if (last_key == "" || key > last_key) { last_key = key; last_bead = id }
      }
    }
    if (last_bead == "") last_bead = ids[1]

    if (dismiss_target != "") {
      for (i = 1; i <= n; i++) if (ids[i] == dismiss_target) { print size[root]; exit 0 }
      continue
    }

    hidden = 0
    for (i = 1; i <= n; i++) if (index(dismissed, " " ids[i] " ") > 0) hidden = 1
    if (hidden) continue

    count++
    f_size[count] = size[root]
    f_body[count] = (name_bead != "") ? name_bead ": " name_text : joined
    f_last[count] = last_bead
    f_date[count] = last_key
  }

  if (dismiss_target != "") exit 0

  # Biggest first - the count is what decides whether to act - then the most recent.
  for (i = 2; i <= count; i++) {
    for (j = i; j > 1; j--) {
      if (f_size[j] > f_size[j - 1] || (f_size[j] == f_size[j - 1] && f_date[j] > f_date[j - 1])) {
        s = f_size[j]; f_size[j] = f_size[j - 1]; f_size[j - 1] = s
        s = f_body[j]; f_body[j] = f_body[j - 1]; f_body[j - 1] = s
        s = f_last[j]; f_last[j] = f_last[j - 1]; f_last[j - 1] = s
        s = f_date[j]; f_date[j] = f_date[j - 1]; f_date[j - 1] = s
      } else break
    }
  }

  if (count == 0) {
    # Threshold spelled as a word, and no separate line for "all of them are dismissed" - a
    # dismissed finding is one that has been dealt with, and saying so again is the nagging the
    # dismissal exists to stop.
    print "No finding has been sighted three times."
  } else {
    printf "Repeated findings (%d+ sightings)\n", threshold
    count_width = 1; body_width = 0
    for (i = 1; i <= count; i++) {
      if (length(f_size[i]) > count_width) count_width = length(f_size[i])
      if (length(f_body[i]) > body_width) body_width = length(f_body[i])
    }
    # Padded by hand rather than with printf's `%*s': the dynamic field width is POSIX but not
    # every awk in the fleet's CI matrix is gawk, and a report that silently loses its columns is a
    # worse trade than four lines of arithmetic.
    for (i = 1; i <= count; i++) {
      print "  " pad(f_size[i], count_width, 1) "  " pad(f_body[i], body_width, 0) "  last: " f_last[i]
    }
  }

  print ""
  if (new_count == "") print "  every retrospective is new"
  else printf "  %s new %s since the last sweep\n", new_count, (new_count == 1 ? "retrospective" : "retrospectives")
}
