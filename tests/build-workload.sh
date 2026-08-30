#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"
consumer="$(consumer_new workload --link consumer-root project-conf build-workload)"
mkdir -p "$consumer/.cerebro"
conf="$consumer/.cerebro/project.conf"
tool="$consumer/.claude/cerebro/scripts/build-workload"
printf 'rust_paths ^(crates/|apps/[^/]+/src-tauri/|Cargo\\.toml$)\n' > "$conf"
out="$(cd "$consumer" && "$tool" --classify crates/core/src/lib.rs)"
[ "$out" = rust ] || fail "Rust path classified as '$out'"
out="$(cd "$consumer" && "$tool" --classify docs/readme.md apps/desktop/src-tauri/src/main.rs)"
[ "$out" = rust ] || fail "mixed paths classified as '$out'"
out="$(cd "$consumer" && "$tool" --classify docs/readme.md packages/ui/index.ts)"
[ "$out" = non-rust ] || fail "non-Rust paths classified as '$out'"
printf 'disk_floor_gb 8\n' > "$conf"
if out="$(cd "$consumer" && "$tool" --classify crates/core/src/lib.rs 2>/dev/null)"; then fail "missing declaration succeeded"; fi
[ -z "$out" ] || fail "missing declaration printed stdout"
if (cd "$consumer" && "$tool" 2>/dev/null); then fail "missing mode succeeded"; fi
if (cd "$consumer" && "$tool" --wat 2>/dev/null); then fail "unknown mode succeeded"; fi
suite_passed
