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

BEGIN {
    _ENV_ROUTES["get"] = "env::get";  _ENV_ARITY["get"] = 1
    _ENV_ROUTES["set"] = "env::set";  _ENV_ARITY["set"] = 2
    _ENV_ROUTES["del"] = "env::del";  _ENV_ARITY["del"] = 1
    _ENV_ROUTES["has"] = "env::has";  _ENV_ARITY["has"] = 1
}

function get(key)      { return ENVIRON[key] }
function set(key, val) { ENVIRON[key] = val }
function del(key)      { delete ENVIRON[key] }
function has(key)      { return (key in ENVIRON) }

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("env", _ENV_ROUTES, _ENV_ARITY, path, a1, a2, a3)
}

@namespace "awk"
