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

function dispatch(path, a1, a2) {
    if (path == "get")  return get(a1)
    if (path == "set")  { set(a1, a2); return }
    if (path == "del")  { del(a1); return }
    if (path == "has")  return has(a1)
    print "env::dispatch: unknown path: " path > "/dev/stderr"
}

@namespace "awk"
