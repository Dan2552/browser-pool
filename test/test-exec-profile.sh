#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$(cd "${SCRIPT_DIR}/../bin" && pwd)/browser-pool"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

elapsed() {
  echo $(( $2 - $1 ))
}

printf 'Profiling browser-pool exec lifecycle\n'
printf '======================================\n\n'

# --- Acquire ---
t0=$(now_ms)
result="$("$BP" acquire --project profile-test 2>/dev/null)"
t1=$(now_ms)

json_line="$(echo "$result" | grep '"lease_id"')"
lease_id="$(echo "$json_line" | sed 's/.*"lease_id":"\([^"]*\)".*/\1/')"
pw_ws="$(echo "$json_line" | sed -n 's/.*"playwright_ws":"\([^"]*\)".*/\1/p')"

printf '  acquire (total)            %4s ms\n' "$(elapsed "$t0" "$t1")"

# --- Simulate child command ---
t2=$(now_ms)
true  # no-op command
t3=$(now_ms)

printf '  child command (no-op)      %4s ms\n' "$(elapsed "$t2" "$t3")"

# --- Release ---
t4=$(now_ms)
"$BP" release "$lease_id" 2>/dev/null
t5=$(now_ms)

printf '  release                    %4s ms\n' "$(elapsed "$t4" "$t5")"

printf '\n  total lifecycle            %4s ms\n' "$(elapsed "$t0" "$t5")"

# --- Now break down acquire into sub-steps ---
printf '\nAcquire breakdown (second run, reusing idle container)\n'
printf '%s\n\n' '------------------------------------------------------'

t0=$(now_ms)
result2="$("$BP" acquire --project profile-test 2>/dev/null)"
t1=$(now_ms)

json_line2="$(echo "$result2" | grep '"lease_id"')"
lease_id2="$(echo "$json_line2" | sed 's/.*"lease_id":"\([^"]*\)".*/\1/')"
container_id="$(echo "$json_line2" | sed 's/.*"container_id":"\([^"]*\)".*/\1/')"

printf '  acquire (reuse, total)     %4s ms\n' "$(elapsed "$t0" "$t1")"

# Check playwright server is responsive
pw_ws2="$(echo "$json_line2" | sed -n 's/.*"playwright_ws":"\([^"]*\)".*/\1/p')"
pw_port="$(echo "$pw_ws2" | sed 's|ws://127.0.0.1:\([0-9]*\)/.*|\1|')"

t6=$(now_ms)
curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${pw_port}/" 2>/dev/null || true
t7=$(now_ms)

printf '  playwright server check    %4s ms\n' "$(elapsed "$t6" "$t7")"

# Release the second lease
t8=$(now_ms)
"$BP" release "$lease_id2" 2>/dev/null
t9=$(now_ms)

printf '  release (second)           %4s ms\n' "$(elapsed "$t8" "$t9")"

# --- Full exec with a real command ---
printf '\nFull exec with real command\n'
printf '%s\n\n' '----------------------------'

t10=$(now_ms)
"$BP" exec --project profile-test -- sleep 0.1 2>/dev/null
t11=$(now_ms)

printf '  exec (sleep 0.1)           %4s ms\n' "$(elapsed "$t10" "$t11")"

# Estimate overhead: total - 100ms sleep
overhead=$(( $(elapsed "$t10" "$t11") - 100 ))
printf '  exec overhead              %4s ms (approx)\n' "$overhead"

printf '\nDone.\n'
