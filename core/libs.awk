# SPDX-License-Identifier: MIT
# core/libs.awk -- libs 読込状態の集約とフラグ
#
# bin/hawk が `-v HAWK_LIBS_<name>=1` を渡している場合のみ
# LIBS_LOADED["<name>"] = 1 を立てる。
# core/*.awk はこれをチェックして分岐する。
#
# サポート対象 libs:
#   net      -- Zig TCP transport
#   binary   -- binary-safe file I/O
#   multipart, crypto, gzip, url, json

BEGIN {
  if (HAWK_LIBS_net)       LIBS_LOADED["net"]       = 1
  if (HAWK_LIBS_binary)    LIBS_LOADED["binary"]    = 1
  if (HAWK_LIBS_multipart) LIBS_LOADED["multipart"] = 1
  if (HAWK_LIBS_crypto)    LIBS_LOADED["crypto"]    = 1
  if (HAWK_LIBS_gzip)      LIBS_LOADED["gzip"]      = 1
  if (HAWK_LIBS_url)       LIBS_LOADED["url"]       = 1
  if (HAWK_LIBS_json)      LIBS_LOADED["json"]      = 1
  if (HAWK_LIBS_cache)     LIBS_LOADED["cache"]     = 1
}
