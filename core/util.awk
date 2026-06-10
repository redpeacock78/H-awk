# SPDX-License-Identifier: MIT
# core/util.awk -- 共通ユーティリティ
#
# 提供関数:
#   url_decode(s)          -- "hello%20world" / "a+b" → デコード
#   escape_html(s)         -- <>&"' を HTML エンティティに置換
#   to_lower(s)            -- ASCII 小文字化 (ヘッダ名正規化用)
#   to_upper(s)            -- ASCII 大文字化
#   log_info(msg)          -- stdout に "[INFO]  ..." 出力
#   log_warn(msg)          -- stderr に "[WARN]  ..." 出力
#   log_error(msg)         -- stderr に "[ERROR] ..." 出力
#   now_ms()               -- 起動時間からのミリ秒 (リクエスト計測用)
#   trim(s)                -- 前後空白除去
#
# 副作用: BEGIN で UTIL_LOWER / UTIL_UPPER テーブルを初期化

BEGIN {
  _util_init()
}

function _util_init(   i, c) {
  for (i = 0; i < 256; i++) UTIL_CHR[i] = sprintf("%c", i)
  for (i = 65; i <= 90; i++) {
    UTIL_LOWER[UTIL_CHR[i]] = UTIL_CHR[i + 32]
    UTIL_UPPER[UTIL_CHR[i + 32]] = UTIL_CHR[i]
  }
}

function url_decode(s,    out, i, n, c, hex) {
  out = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "+") {
      out = out " "
    } else if (c == "%" && i + 2 <= n) {
      hex = substr(s, i + 1, 2)
      out = out sprintf("%c", strtonum("0x" hex))
      i += 2
    } else {
      out = out c
    }
  }
  return out
}

function escape_html(s,    out) {
  out = s
  gsub(/&/,  "\\&amp;",  out)
  gsub(/</,  "\\&lt;",   out)
  gsub(/>/,  "\\&gt;",   out)
  gsub(/"/,  "\\&quot;", out)
  gsub(/'/,  "\\&#39;",  out)
  return out
}

function to_lower(s,    out, i, n, c) {
  out = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    out = out (c in UTIL_LOWER ? UTIL_LOWER[c] : c)
  }
  return out
}

function to_upper(s,    out, i, n, c) {
  out = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    out = out (c in UTIL_UPPER ? UTIL_UPPER[c] : c)
  }
  return out
}

function log_info(msg) {
  printf "[INFO]  %s\n", msg
  fflush()
}

function log_warn(msg) {
  printf "[WARN]  %s\n", msg > "/dev/stderr"
  fflush("/dev/stderr")
}

function log_error(msg) {
  printf "[ERROR] %s\n", msg > "/dev/stderr"
  fflush("/dev/stderr")
}

function now_ms() {
  return systime() * 1000
}

function trim(s) {
  sub(/^[ \t\r\n]+/, "", s)
  sub(/[ \t\r\n]+$/, "", s)
  return s
}
