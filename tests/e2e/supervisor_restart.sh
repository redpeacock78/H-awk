#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/e2e/supervisor_restart.sh
set -e

PORT=18181
PASS=0; FAIL=0

check() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual"   >&2
  fi
}

HAWK_RUN_DIR=$(mktemp -d)
export HAWK_RUN_DIR HAWK_WORKERS=2 PORT

./bin/hawk tests/e2e/fixtures/app.awk > /tmp/hawk_sup_test.log 2>&1 &
SERVER=$!
trap 'kill -TERM "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; rm -rf "$HAWK_RUN_DIR"' EXIT INT TERM

for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  sleep 0.3
done

check "initial request" "hello" "$(curl -s http://127.0.0.1:$PORT/)"

worker_pid=$(ls "$HAWK_RUN_DIR/pids/" 2>/dev/null | head -1 | sed 's/\.token//')
if [ -n "$worker_pid" ]; then
  kill -KILL "$worker_pid" 2>/dev/null || true
  sleep 1.5
  check "request after restart" "hello" "$(curl -s http://127.0.0.1:$PORT/)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: no worker pid found in HAWK_RUN_DIR" >&2
fi

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
