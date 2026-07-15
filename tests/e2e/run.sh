#!/bin/sh
# SPDX-License-Identifier: MIT
# H-awk E2E runner
# 起動 → curl リクエスト → assert → 終了。
# 失敗があれば exit 1。

set -e

PORT=18180
PORT=$PORT \
HAWK_MAX_HEADER_SIZE=1024 \
HAWK_MAX_BODY_SIZE=1024 \
  ./bin/hawk tests/e2e/fixtures/app.awk > tests/e2e/server.log 2>&1 &
SERVER=$!
trap 'kill -TERM "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true' EXIT INT TERM

# 起動待ち (最大 5 秒)
attempt=0
until curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -ge 50 ] && break
  sleep 0.1
done

PASS=0
FAIL=0
SKIP=0
check() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"     >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual"   >&2
  fi
}

# --- 基本 ---
check "GET / 200"   "200" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/)"
check "GET / body"  "hello" "$(curl -s http://127.0.0.1:$PORT/)"

# --- :param ---
check "GET /users/42" "user=42" "$(curl -s http://127.0.0.1:$PORT/users/42)"

# --- POST form-urlencoded + JSON response ---
check "POST /echo status" "201" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'msg=hi' http://127.0.0.1:$PORT/echo)"
check "POST /echo body"   '{"got":"hi"}' "$(curl -s -X POST -d 'msg=hi' http://127.0.0.1:$PORT/echo)"

# --- 静的ファイル (実 public/style.css を使う) ---
check "GET /style.css 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/style.css)"

# --- render() ---
check "GET /render-html status" "200" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/render-html)"

# --- 404 / 405 ---
check "GET /missing 404"     "404" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/missing)"
check "DELETE / 405"          "405" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:$PORT/)"

# --- 入力サイズ制限 ---
# header size 制限超過 (1024 設定なので、長いカスタムヘッダで超える)
big=$(printf 'X-Big: %s' "$(head -c 1100 /dev/zero | tr '\0' 'a')")
check "431 on big header" "431" "$(curl -s -o /dev/null -w '%{http_code}' -H "$big" http://127.0.0.1:$PORT/)"
# body 128 byte 制限超過
check "413 on big body" "413" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data "$(head -c 1100 /dev/zero | tr '\0' 'a')" -H 'Content-Type: application/x-www-form-urlencoded' http://127.0.0.1:$PORT/echo)"

# ---- binary integrity test ----
# public/test.bin: 16 bytes (0x00-0x0f) with null bytes.
# Served via static.awk → res["_binary_path"] → hawk_bin_read + hawk_net_respond.
_bin_tmp=$(mktemp /tmp/hawk_e2e_bin.XXXXXX)
curl -s "http://127.0.0.1:$PORT/test.bin" -o "$_bin_tmp" 2>/dev/null
check "binary integrity" "ok" "$(cmp -s public/test.bin "$_bin_tmp" && echo ok || echo fail)"
rm -f "$_bin_tmp"

echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
