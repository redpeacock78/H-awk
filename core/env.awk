# SPDX-License-Identifier: MIT
# core/env.awk -- env:: namespace: ENVIRON ラッパー (Deno.env スタイル)
#
# 提供関数:
#   env::get(key)       -- ENVIRON[key] を返す。未定義時 "" を返す
#   env::set(key, val)  -- ENVIRON[key] = val
#   env::del(key)       -- delete ENVIRON[key]
#   env::has(key)       -- key in ENVIRON → 1 または 0
#
# 注意: env::set の変更は同プロセス内のみ有効。子プロセスへは伝播しない（gawk 仕様）

@namespace "env"

function get(key)      { return ENVIRON[key] }
function set(key, val) { ENVIRON[key] = val }
function del(key)      { delete ENVIRON[key] }
function has(key)      { return (key in ENVIRON) }

@namespace "awk"
