# SPDX-License-Identifier: MIT
# core/dispatch.awk -- namespace dispatch 共通ルーター
#
# 使い方:
#   各 namespace の BEGIN ブロックで routes テーブルを設定し、
#   dispatch() 関数から hawk_dispatch::call() を呼ぶ。
#
# 例:
#   BEGIN { _ENV_ROUTES["get"] = "env::get" }
#   function dispatch(path, a1, a2, a3) {
#       return hawk_dispatch::call("env", _ENV_ROUTES, path, a1, a2, a3)
#   }

@namespace "hawk_dispatch"

function call(ns, routes, path, a1, a2, a3,    _fn) {
    if (!(path in routes)) {
        print ns "::dispatch: unknown path: " path > "/dev/stderr"
        return ""
    }
    _fn = routes[path]
    return @_fn(a1, a2, a3)
}

@namespace "awk"
