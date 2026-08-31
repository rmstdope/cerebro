#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/consumer.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -x "$root/scripts/cerebro-tui" ]] || { echo "launcher is not executable" >&2; exit 1; }
if "$root/scripts/cerebro-tui" --unexpected >/dev/null 2>&1; then
 echo "launcher accepted arguments" >&2; exit 1
fi
suite_passed
