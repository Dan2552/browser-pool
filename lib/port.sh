#!/usr/bin/env bash
# Port allocation from a configurable range.

bp_used_ports() {
  local id
  for id in $(bp_list_containers); do
    bp_container_port "$id"
  done
}

bp_port_in_use_on_host() {
  local port="$1"
  if command -v lsof > /dev/null 2>&1; then
    lsof -i :"$port" > /dev/null 2>&1
  elif command -v ss > /dev/null 2>&1; then
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q .
  else
    # fallback: try to bind
    (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null
  fi
}

bp_allocate_port() {
  local used
  used="$(bp_used_ports)"

  local port
  for port in $(seq "$BROWSER_POOL_PORT_RANGE_START" "$BROWSER_POOL_PORT_RANGE_END"); do
    # Skip if already used by a pool container
    if echo "$used" | grep -qx "$port" 2>/dev/null; then
      continue
    fi
    # Skip if bound on host by something else
    if bp_port_in_use_on_host "$port"; then
      continue
    fi
    echo "$port"
    return 0
  done

  bp_log "ERROR: No available ports in range ${BROWSER_POOL_PORT_RANGE_START}-${BROWSER_POOL_PORT_RANGE_END}"
  return 1
}
