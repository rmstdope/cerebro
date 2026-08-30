#!/usr/bin/env bash
#
# Proves scripts/disk-preflight refuses to start a bead on a disk with no room to build in
# (ah-qled.7.2, cerebro#58 §2), reading its floor from the consumer's own `disk_floor_gb'.
#
# A build that runs out of disk does not say so: it fails inside the linker or the code generator,
# with a message that reads like a fault in the code being compiled - and an agent then goes and
# tries to fix code that was never wrong. So the failure is moved to the front where it can be
# stated plainly. The disk this was written for reached 100% capacity with 2.0 GiB free while three
# worktrees each kept a build tree of their own.
#
# Ported from the consumer's scripts/diskPreflight.test.ts, which is the specification. `df' and
# `du' are stubbed ahead of the real ones on PATH, exactly as tests/prune-worktrees.sh does, so the
# test rather than the machine decides what the disk looks like.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/disk-preflight.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- stubs -------------------------------------------------------------------------------------
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
free_kb_file="$work_dir/free_kb"
du_kb_file="$work_dir/du_kb"
cargo_mode_file="$work_dir/cargo_mode"
cargo_summary_file="$work_dir/cargo_summary"
cargo_args_file="$work_dir/cargo_args"
cargo_pwd_file="$work_dir/cargo_pwd"
echo 0 > "$du_kb_file"
echo success > "$cargo_mode_file"
echo 'Summary 1 files, 5.7GiB total' > "$cargo_summary_file"

cat > "$stub_dir/df" <<STUB
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 240000000 100000000 \$(cat "$free_kb_file") 50% /"
STUB
chmod +x "$stub_dir/df"

# Every directory is the same size, which is all these assertions need: what is being tested is
# that the sizes are reported and totalled, not that `du' can count.
cat > "$stub_dir/du" <<STUB
#!/usr/bin/env bash
echo "\$(cat "$du_kb_file")	\${*: -1}"
STUB
chmod +x "$stub_dir/du"
cat > "$stub_dir/cargo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$PWD" > "$cargo_pwd_file"
printf '%s\n' "\$*" > "$cargo_args_file"
[ "\$(cat "$cargo_mode_file")" = success ] || { echo "cargo fixture failed" >&2; exit 1; }
cat "$cargo_summary_file"
STUB
chmod +x "$stub_dir/cargo"

export PATH="$stub_dir:$PATH"

# Free space, in gigabytes, possibly fractional - 4.96 is the case that matters most.
free_gb() { awk -v gb="$1" 'BEGIN { printf "%d\n", gb * 1024 * 1024 }' > "$free_kb_file"; }
tree_gb() { awk -v gb="$1" 'BEGIN { printf "%d\n", gb * 1024 * 1024 }' > "$du_kb_file"; }

# --- a throwaway consumer, the way tests/project-conf.sh builds one -----------------------------
consumer="$(consumer_new repo --link consumer-root project-conf disk-preflight)"
conf="$consumer/.cerebro/project.conf"
mkdir -p "$consumer/.cerebro"
preflight="$consumer/.claude/cerebro/scripts/disk-preflight"

# stdout on either exit path, and the exit status alongside it.
run() {
  local out status
  set +e
  out="$(cd "$consumer" && "$preflight" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$out"
  return $status
}

# --- a consumer that declares no floor gets no preflight at all --------------------------------
#
# `project-conf' never fails on absence, which is what makes that a one-line branch - and a
# consumer adopting the fleet must not be refused a bead by a number cerebro made up.
printf 'project_name  Nothing declared\n' > "$conf"
free_gb 1
out="$(run)" || fail "no floor declared: expected exit 0, got non-zero"
[ -z "$out" ] || fail "no floor declared: expected silence, got '$out'"
pass "a consumer that declares no floor gets no preflight, silently and successfully"

printf 'disk_floor_gb  8\nreclaim_dirs   target\n' > "$conf"

# --- explicit non-Rust workload uses its declared floor -----------------------------------------
printf 'disk_floor_gb  8\ndisk_floor_non_rust_gb  2\nreclaim_dirs target\n' > "$conf"
: > "$cargo_args_file"
free_gb 4.4
out="$(cd "$consumer" && "$preflight" --workload non-rust)" || fail "non-Rust floor should pass"
grep -q 'above the 2 GB floor for non-Rust work' <<<"$out" || fail "non-Rust label missing: $out"
if out="$(cd "$consumer" && "$preflight" --workload rust 2>&1)"; then fail "Rust floor should refuse"; fi
grep -q 'below the 8 GB floor for Rust work' <<<"$out" || fail "Rust floor missing: $out"
free_gb 1.7
if out="$(cd "$consumer" && "$preflight" --workload non-rust 2>&1)"; then fail "non-Rust below floor should refuse"; fi
grep -q 'A check that runs out of space can fail in a tool' <<<"$out" || fail "non-Rust explanation missing"
grep -q 'No declared reclaim can recover' <<<"$out" || fail "non-Rust reclaim message missing"
[ ! -s "$cargo_args_file" ] || fail "non-Rust preflight invoked Cargo"
pass "explicit non-Rust workload uses its floor without Cargo"

# --- non-Rust falls back to the full floor when undeclared --------------------------------------
printf 'disk_floor_gb  8\nreclaim_dirs target\n' > "$conf"
free_gb 4.4
if out="$(cd "$consumer" && "$preflight" --workload non-rust 2>&1)"; then fail "undeclared non-Rust floor should refuse"; fi
grep -q 'using 8 GB full-build floor' <<<"$out" || fail "fallback unit missing: $out"
grep -q 'below the 8 GB floor for Rust work' <<<"$out" || fail "fallback label missing: $out"
pass "undeclared non-Rust workload uses the full floor"

# --- room to build --------------------------------------------------------------------------
free_gb 20
out="$(run)" || fail "20 GB free: expected exit 0"
grep -q '20 GB free' <<<"$out" || fail "20 GB free: the number should be in the message, got: $out"
grep -q 'above the 8 GB floor' <<<"$out" || fail "20 GB free: expected the floor named, got: $out"
pass "a disk with room says what is free and what the floor was, and exits 0"

# --- the floor exactly is already too little ---------------------------------------------------
#
# `prune-worktrees.sh' makes the same test - headroom is MORE than the floor - so the two can never
# disagree about whether there is room to build. An `>=' here reintroduces exactly the drift this
# bead removed.
free_gb 8
if out="$(run)"; then
  fail "at the floor exactly: expected a refusal, got: $out"
fi
grep -q 'below the 8 GB floor' <<<"$out" || fail "at the floor: expected a refusal, got: $out"
pass "the floor exactly is refused, matching prune-worktrees.sh's own test"

# --- below the floor ---------------------------------------------------------------------------
free_gb 2
if out="$(run)"; then
  fail "2 GB free: expected a refusal"
fi
grep -q 'below the 8 GB floor' <<<"$out" || fail "2 GB free: expected a refusal, got: $out"
grep -q 'linker' <<<"$out" \
  || fail "2 GB free: the refusal must say why a full disk reads like a code error, got: $out"
pass "a refusal says what is free, what was wanted, and why it matters"

# --- a refusal never rounds itself up into looking like a pass ---------------------------------
#
# 4.96 rounded to one decimal is "5.0", and "5.0 GB free, below the 5 GB floor" argues with itself
# at exactly the moment someone needs to believe it.
printf 'disk_floor_gb  5\nreclaim_dirs   target\n' > "$conf"
free_gb 4.96
if out="$(run)"; then
  fail "4.96 GB free: expected a refusal"
fi
grep -q '4.9 GB free' <<<"$out" || fail "4.96 GB: expected a truncated 4.9, got: $out"
grep -q '5.0 GB free' <<<"$out" && fail "4.96 GB: rounded a refusal up into a contradiction: $out"
pass "a refusal is truncated, never rounded up into overstating what is there"

printf 'disk_floor_gb  8\nreclaim_dirs   target\n' > "$conf"

# --- what is reclaimable, and where ------------------------------------------------------------
#
# Every worktree builds its own tree (ah-gdp), so what fills a nearly-full disk is several of them
# rather than one a single clean would empty. Eleven retrospectives complain that the advice sent
# the reader to a sweep that reclaimed nothing, so the OFFLINE reclaims are named outright.
mkdir -p "$consumer/target" "$consumer/.cerebro/worktrees/ah-x/target"
tree_gb 1.9
free_gb 2
if out="$(run)"; then
  fail "with build trees: expected a refusal"
fi
grep -q '3.8 GB sits in 2 build trees' <<<"$out" \
  || fail "reclaimable: expected the total and the count, got: $out"
grep -q 'target (1.9 GB)' <<<"$out" || fail "reclaimable: each tree names its own size, got: $out"
grep -q '.cerebro/worktrees/ah-x/target' <<<"$out" \
  || fail "reclaimable: a worktree's tree is reclaimable too, got: $out"
grep -q 'cargo/registry/src' <<<"$out" \
  && fail "reclaimable: old fixed cache advice must be gone, got: $out"
pass "a refusal names each build tree and the total without fixed cache advice"

# --- a sufficient package reclaim is measured and recommended -------------------------------
printf 'disk_floor_gb  8\nreclaim_dirs   target\ncargo_reclaim_packages atlantis-hud-core\n' > "$conf"
free_gb 5.7
if out="$(run)"; then
  fail "sufficient package reclaim: expected refusal with advice"
fi
grep -q "To recover the missing 2.3 GB, run from $consumer:" <<<"$out" \
  || fail "sufficient package reclaim: expected absolute command root, got: $out"
grep -q '^  cargo clean -p atlantis-hud-core$' <<<"$out" \
  || fail "sufficient package reclaim: expected command, got: $out"
grep -q -- '--dry-run --offline --package atlantis-hud-core' "$cargo_args_file" \
  || fail "sufficient package reclaim: expected safe Cargo arguments"
[ "$(cat "$cargo_pwd_file")" = "$consumer" ] \
  || fail "sufficient package reclaim: Cargo should run from shared root"
pass "a sufficient package reclaim is measured and recommended"

# --- insufficient and failed package reclaims are explicit -----------------------------------
echo 'Summary 1 files, 0.5GiB total' > "$cargo_summary_file"
free_gb 7
if out="$(run)"; then
  fail "insufficient package reclaim: expected refusal"
fi
grep -q 'No declared reclaim can recover the missing 1 GB.' <<<"$out" \
  || fail "insufficient package reclaim: expected unavailable advice, got: $out"
echo failure > "$cargo_mode_file"
free_gb 2
if out="$(run)"; then
  fail "failed package reclaim: expected refusal"
fi
grep -q 'Reclaim measurement failed; cargo clean was not recommended.' <<<"$out" \
  || fail "failed package reclaim: expected measurement error, got: $out"
grep -q 'cargo fixture failed' <<<"$out" \
  && fail "failed package reclaim: leaked Cargo output, got: $out"
pass "insufficient and failed package reclaims are not recommended"
echo success > "$cargo_mode_file"

# --- a build tree at the retired worktree path is not a build tree ----------------------------
#
# `.claude/worktrees/` is where trees lived before ah-v82 and nothing writes there (cb-k6r). The
# preflight looks at the one home only: a directory left at the old path is not counted, not
# named, and not offered as something to reclaim.
mkdir -p "$consumer/.claude/worktrees/ah-old/target"
free_gb 2
if out="$(run)"; then
  fail "retired path: expected a refusal"
fi
grep -q '3.8 GB sits in 2 build trees' <<<"$out" \
  || fail "retired path: a tree at .claude/worktrees/ was counted, got: $out"
grep -q '.claude/worktrees' <<<"$out" \
  && fail "retired path: a tree at .claude/worktrees/ was named, got: $out"
rm -rf "$consumer/.claude/worktrees"
pass "a build tree at the retired .claude/worktrees/ path is neither counted nor named"

# --- the reclaimable line is appended to a pass too --------------------------------------------
free_gb 20
out="$(run)" || fail "20 GB with trees: expected exit 0"
grep -q 'above the 8 GB floor' <<<"$out" || fail "pass with trees: expected the pass verdict"
grep -q '3.8 GB sits in 2 build trees' <<<"$out" \
  || fail "pass with trees: a build tree is worth reclaiming either way, got: $out"
pass "the reclaimable line is appended to a pass too - the sweep is worth running either way"

# --- one tree is not spoken of in the plural ---------------------------------------------------
# Only the worktrees go: since cb-epr the project's own declaration lives under `.cerebro/` too, and
# removing the directory wholesale would take the floor this case is asserting against with it.
rm -rf "$consumer/.cerebro/worktrees"
out="$(run)" || fail "one tree: expected exit 0"
grep -q '1 build tree:' <<<"$out" || fail "one tree: expected the singular, got: $out"
grep -q '1 build trees' <<<"$out" && fail "one tree: spoke of one tree in the plural: $out"
pass "one build tree is not spoken of in the plural"

# --- nothing to reclaim is said by saying nothing ----------------------------------------------
rm -rf "$consumer/target"
out="$(run)" || fail "no trees: expected exit 0"
grep -q 'build tree' <<<"$out" && fail "no trees: invented a reclaimable line, got: $out"
pass "nothing to reclaim is reported by saying nothing about it"

# --- the environment still wins, for a consumer that keeps its floor elsewhere -----------------
free_gb 20
if out="$(cd "$consumer" && FREE_SPACE_FLOOR_GB=50 "$preflight" 2>&1)"; then
  fail "env floor: 20 GB is below an environment floor of 50 and should be refused"
fi
grep -q 'below the 50 GB floor' <<<"$out" || fail "env floor: expected the environment's number, got: $out"
pass "FREE_SPACE_FLOOR_GB in the environment wins over the declaration"

suite_passed
