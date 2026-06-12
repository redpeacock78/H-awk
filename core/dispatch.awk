# SPDX-License-Identifier: MIT
# core/dispatch.awk -- namespace dispatch 共通ルーター
#
# 使い方:
#   各 namespace の BEGIN ブロックで routes テーブルを設定し、
#   dispatch() 関数から hawk_dispatch::call() を呼ぶ。
#
# 例:
#   BEGIN { _ENV_ROUTES["get"] = "env::get"; _ENV_ARITY["get"] = 1 }
#   function dispatch(path, a1, a2, a3) {
#       return hawk_dispatch::call("env", _ENV_ROUTES, _ENV_ARITY, path, a1, a2, a3)
#   }

@namespace "hawk_dispatch"

function call(ns, routes, arity_tbl, path, a1, a2, a3,    _fn, _ar) {
    if (!(path in routes)) {
        print ns "::dispatch: unknown path: " path > "/dev/stderr"
        return ""
    }
    _fn = routes[path]
    if (path in arity_tbl) {
        _ar = arity_tbl[path]
    } else {
        print ns "::dispatch: missing arity for path: " path " (defaulting to 3)" > "/dev/stderr"
        _ar = 3
    }
    if      (_ar == 0) return @_fn()
    else if (_ar == 1) return @_fn(a1)
    else if (_ar == 2) return @_fn(a1, a2)
    else if (_ar == 3) return @_fn(a1, a2, a3)
    else {
        print ns "::dispatch: invalid arity " _ar " for path: " path > "/dev/stderr"
        return ""
    }
}

@namespace "awk"
