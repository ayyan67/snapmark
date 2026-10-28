#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${1:-zig-out/bin/snapmark}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PATH="$ROOT_DIR/zig-out/bench.log"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH"
  exit 1
fi

mkdir -p "$ROOT_DIR/zig-out"
rm -f "$LOG_PATH"

SNAPMARK_BENCH_AUTOCLOSE=35 "$BIN_PATH" >"$LOG_PATH" 2>&1 &
PID=$!

echo "bench_pid=$PID"

sleep 10
RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ' || true)"

echo "rss_kb_after_10s=${RSS_KB:-n/a}"

sleep 20
CPU_PCT="$(ps -o %cpu= -p "$PID" | tr -d ' ' || true)"

echo "cpu_pct_after_30s=${CPU_PCT:-n/a}"

wait "$PID" || true

STARTUP_LINE="$(rg -N "startup_ms=" "$LOG_PATH" | head -n 1 || true)"
echo "${STARTUP_LINE:-startup_ms=unavailable}"
echo "bench_log=$LOG_PATH"
