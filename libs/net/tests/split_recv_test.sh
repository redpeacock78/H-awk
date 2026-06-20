#!/usr/bin/env bash
# Split receive test: header and body arrive in separate writes.
set -euo pipefail

PORT=18765
OUT=/tmp/hawk_split_test

./libs/net/zig-out/bin/hawk-net-test-server "$PORT" &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null || true; rm -f "$OUT"' EXIT

sleep 0.2
{
    printf 'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\n\r\n'
    sleep 0.1
    printf 'msg=hey'
} | nc -w2 localhost "$PORT" > "$OUT" 2>&1 || true

grep -q "200" "$OUT" || {
    echo "FAIL: split recv - no 200 response"
    exit 1
}
echo "PASS: split recv"
