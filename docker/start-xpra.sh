#!/usr/bin/env bash
set -euo pipefail

XPRA_DISPLAY="${XPRA_DISPLAY:-:100}"
XPRA_PORT="${XPRA_PORT:-14500}"
XPRA_START_SHELL="${XPRA_START_SHELL:-0}"
BROWSER_POOL_IDLE_TTL="${BROWSER_POOL_IDLE_TTL:-0}"

START_ARGS=()

if [[ "${XPRA_START_SHELL}" != "0" ]]; then
  if [[ -n "${PLAYWRIGHT_XPRA_COMMAND:-}" ]]; then
    STARTUP_COMMAND="${PLAYWRIGHT_XPRA_COMMAND}"
  else
    STARTUP_COMMAND=$(cat <<'HEREDOC'
printf '\nbrowser-pool XPRA desktop is ready.\n\n'
exec bash -il
HEREDOC
)
  fi

  STARTUP_SCRIPT="/tmp/xpra-terminal-command.sh"
  printf '%s\n' "${STARTUP_COMMAND}" > "${STARTUP_SCRIPT}"
  chmod +x "${STARTUP_SCRIPT}"
  XTERM_COMMAND="xterm -fa Monospace -fs 11 -geometry 160x48 -e /bin/bash ${STARTUP_SCRIPT}"
  START_ARGS+=(--start="${XTERM_COMMAND}")
fi

# Optional idle watchdog: if BROWSER_POOL_IDLE_TTL > 0, stop the container
# after that many seconds of no Chromium/Playwright processes running.
if [[ "${BROWSER_POOL_IDLE_TTL}" -gt 0 ]] 2>/dev/null; then
  (
    idle_since=""
    while true; do
      sleep 30
      if pgrep -f "chromium|playwright" > /dev/null 2>&1; then
        idle_since=""
      else
        if [[ -z "$idle_since" ]]; then
          idle_since="$(date +%s)"
        fi
        now="$(date +%s)"
        elapsed="$((now - idle_since))"
        if [[ "$elapsed" -ge "${BROWSER_POOL_IDLE_TTL}" ]]; then
          kill 1 2>/dev/null || true
          exit 0
        fi
      fi
    done
  ) &
fi

exec xpra start "${XPRA_DISPLAY}" \
  --bind-tcp=0.0.0.0:"${XPRA_PORT}" \
  --html=on \
  --daemon=no \
  --mdns=no \
  --dbus-launch= \
  --pulseaudio=no \
  --notifications=no \
  --webcam=no \
  --printing=no \
  --file-transfer=no \
  --open-files=no \
  --open-url=no \
  --exit-with-children=no \
  "${START_ARGS[@]}"
