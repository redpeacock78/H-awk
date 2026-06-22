#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/e2e/shared_cache_multiworker.sh — shared cache multi-worker e2e

set -e
PORT=18182
PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
  fi
}

case "$(uname -s)" in
  Darwin) SO_EXT=dylib ;;
  *)      SO_EXT=so ;;
esac
CACHE_SO="libs/cache/zig-out/lib/libhawk_cache.${SO_EXT}"
if [[ ! -f "$CACHE_SO" ]]; then
  echo "SKIP: libs/cache not built ($CACHE_SO not found)" >&2
  exit 0
fi
NET_SO="libs/net/zig-out/lib/libhawk_net.${SO_EXT}"
if [[ ! -f "$NET_SO" ]]; then
  echo "SKIP: libs/net not built ($NET_SO not found)" >&2
  exit 0
fi

PROBE_RUN_DIR=$(mktemp -d)
HAWK_RUN_DIR="$PROBE_RUN_DIR" HAWK_WORKERS=1 HAWK_CACHE_BACKEND=zig HAWK_SHARED_CACHE_SIZE=512K HAWK_SUPERVISED=1 PORT=18183 \
  ./bin/hawk tests/e2e/fixtures/cache_app.awk >/tmp/hawk_cache_e2e_probe.log 2>&1 &
PROBE=$!
sleep 1
if ! kill -0 "$PROBE" 2>/dev/null; then
  wait "$PROBE" 2>/dev/null || true
  rm -rf "$PROBE_RUN_DIR"
  echo "SKIP: libs/net cannot bind in this environment" >&2
  exit 0
fi
kill -TERM "$PROBE" 2>/dev/null || true
wait "$PROBE" 2>/dev/null || true
rm -rf "$PROBE_RUN_DIR"

HAWK_RUN_DIR=$(mktemp -d)
export HAWK_RUN_DIR HAWK_WORKERS=2 HAWK_CACHE_BACKEND=zig HAWK_SHARED_CACHE_SIZE=512K PORT

./bin/hawk tests/e2e/fixtures/cache_app.awk >/tmp/hawk_cache_e2e.log 2>&1 &
SERVER=$!
trap 'kill -TERM "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; rm -rf "$HAWK_RUN_DIR"' EXIT INT TERM

for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/cache/get" 2>/dev/null && break
  sleep 0.3
done

set_result=$(curl -s "http://127.0.0.1:$PORT/cache/set")
check "cache/set returns ok" "ok" "$set_result"

results=$(seq 50 | xargs -n1 -P8 curl -s "http://127.0.0.1:$PORT/cache/get")
distinct=$(echo "$results" | sort -u)
check "all 50 requests return shared-value" "shared-value" "$distinct"

worker_ids=$(seq 50 | xargs -n1 -P8 curl -s "http://127.0.0.1:$PORT/worker" | sort -u | tr '\n' ',')
echo "worker IDs seen: $worker_ids"

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
