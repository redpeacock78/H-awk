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

# 起動待ち (最大 3 秒)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    break
  fi
  sleep 0.3
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

# ---- binary integrity test (requires libs/binary) ----
_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    echo ""
  fi
}

TEXT_FILE="public/style.css"
if [ ! -f "$TEXT_FILE" ]; then
  echo "SKIP: $TEXT_FILE not found (binary integrity)"
  SKIP=$((SKIP + 1))
else
  ORIG_MD5=$(_md5 "$TEXT_FILE")
  TMP_RECV=$(mktemp)
  curl -s "http://127.0.0.1:${PORT}/style.css" -o "$TMP_RECV"
  RECV_MD5=$(_md5 "$TMP_RECV")
  rm -f "$TMP_RECV"

  LIB_SO=""
  for ext in so dylib; do
    if [ -f "libs/binary/zig-out/lib/libhawk_binary.${ext}" ]; then
      LIB_SO="found"; break
    fi
  done

  if [ -z "$ORIG_MD5" ]; then
    echo "SKIP: md5 tool not found"
    SKIP=$((SKIP + 1))
  elif [ "$ORIG_MD5" = "$RECV_MD5" ]; then
    echo "PASS: binary integrity (style.css md5 matches)"
    PASS=$((PASS + 1))
  elif [ -z "$LIB_SO" ]; then
    echo "SKIP: libs/binary not built (binary integrity requires it)"
    SKIP=$((SKIP + 1))
  else
    echo "FAIL: binary integrity (orig=$ORIG_MD5 served=$RECV_MD5)" >&2
    FAIL=$((FAIL + 1))
  fi
fi

echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
