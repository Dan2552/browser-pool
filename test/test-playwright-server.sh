#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$(cd "${SCRIPT_DIR}/../bin" && pwd)/browser-pool"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

cleanup_lease=""
trap 'if [[ -n "$cleanup_lease" ]]; then "$BP" release "$cleanup_lease" 2>/dev/null || true; fi' EXIT

printf 'Test: acquire returns playwright_ws\n'

result="$("$BP" acquire --project test-pw)"
cleanup_lease="$(echo "$result" | grep '"lease_id"' | sed 's/.*"lease_id":"\([^"]*\)".*/\1/')"

# Check JSON fields exist
if echo "$result" | grep -q '"playwright_ws"'; then
  pass "acquire JSON contains playwright_ws"
else
  fail "acquire JSON missing playwright_ws"
fi

pw_ws="$(echo "$result" | grep '"playwright_ws"' | sed -n 's/.*"playwright_ws":"\([^"]*\)".*/\1/p')"
if [[ "$pw_ws" == ws://* ]]; then
  pass "playwright_ws is a ws:// URL: ${pw_ws}"
else
  fail "playwright_ws is not a ws:// URL: ${pw_ws}"
fi

xpra_port="$(echo "$result" | grep '"xpra_port"' | sed 's/.*"xpra_port":\([0-9]*\).*/\1/')"
pw_port="$(echo "$pw_ws" | sed 's|ws://127.0.0.1:\([0-9]*\)/.*|\1|')"
if [[ "$xpra_port" != "$pw_port" ]]; then
  pass "xpra port (${xpra_port}) != playwright port (${pw_port})"
else
  fail "xpra and playwright ports are the same (${xpra_port})"
fi

printf '\nTest: playwright WebSocket is connectable\n'

# Check that the playwright server is actually listening on the port
if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${pw_port}/"; then
  pass "playwright server port ${pw_port} is reachable"
else
  # Playwright server may reject HTTP but still be listening — try a ws upgrade
  if curl -sf -o /dev/null --max-time 5 -H "Upgrade: websocket" -H "Connection: Upgrade" "http://127.0.0.1:${pw_port}/" 2>/dev/null; then
    pass "playwright server port ${pw_port} is reachable (ws upgrade)"
  else
    # As a last resort, just check if something is listening
    if lsof -i :"${pw_port}" > /dev/null 2>&1; then
      pass "playwright server port ${pw_port} has a listener"
    else
      fail "playwright server port ${pw_port} is not reachable"
    fi
  fi
fi

printf '\nTest: exec sets BROWSER_POOL_PLAYWRIGHT_WS\n'

exec_output="$("$BP" exec --project test-pw -- bash -c 'echo "PW_WS=${BROWSER_POOL_PLAYWRIGHT_WS:-unset}"' 2>&1)"
pw_ws_from_exec="$(echo "$exec_output" | grep '^PW_WS=' | sed 's/PW_WS=//')"

if [[ "$pw_ws_from_exec" == ws://* ]]; then
  pass "BROWSER_POOL_PLAYWRIGHT_WS set in exec: ${pw_ws_from_exec}"
else
  fail "BROWSER_POOL_PLAYWRIGHT_WS not set in exec: ${pw_ws_from_exec}"
fi

printf '\nTest: exec releases cleanly (no unbound variable)\n'

exec_stderr="$("$BP" exec --project test-pw -- true 2>&1 >/dev/null)" || true
if echo "$exec_stderr" | grep -qi "unbound variable"; then
  fail "exec cleanup has unbound variable error"
else
  pass "exec cleanup is clean"
fi

printf '\nTest: release works\n'

"$BP" release "$cleanup_lease" 2>/dev/null && release_ok=true || release_ok=false
cleanup_lease=""

if [[ "$release_ok" == "true" ]]; then
  pass "release succeeded"
else
  fail "release failed"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
