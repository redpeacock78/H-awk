# SPDX-License-Identifier: MIT
# core/hawk.awk -- hawk:: App API (Hono-style)
#
# hawk:: は H-awk の一次ルーティング API。
# GET/POST/... は後方互換エイリアスとして core/router.awk で定義する。

@namespace "hawk"

function get(path, handler)    { awk::_route_add("GET",    path, handler) }
function post(path, handler)   { awk::_route_add("POST",   path, handler) }
function put(path, handler)    { awk::_route_add("PUT",    path, handler) }
function del(path, handler)    { awk::_route_add("DELETE", path, handler) }
function patch(path, handler)  { awk::_route_add("PATCH",  path, handler) }
function head(path, handler)   { awk::_route_add("HEAD",   path, handler) }

function on(methods, paths, handler) {
  # Delegate to awk:: namespace to use isarray() built-in
  return awk::_on_impl(methods, paths, handler)
}

function all(paths, handler) {
  # Delegate to awk:: namespace to use isarray() built-in
  return awk::_all_impl(paths, handler)
}

function listen(port) {
    if (port !~ /^[0-9]+$/ || port + 0 == 0) {
        print "hawk::listen: invalid port: \"" port "\"" > "/dev/stderr"
        exit 1
    }
    awk::listen(port + 0)
}

# dispatch: DSL desugar target — hawk.app.get(...) → hawk::dispatch("app.get", ...)
function dispatch(path, a1, a2, a3) {
    if (path == "app.get")    { get(a1, a2);      return }
    if (path == "app.post")   { post(a1, a2);     return }
    if (path == "app.put")    { put(a1, a2);      return }
    if (path == "app.del")    { del(a1, a2);      return }
    if (path == "app.patch")  { patch(a1, a2);    return }
    if (path == "app.head")   { head(a1, a2);     return }
    if (path == "app.on")     { on(a1, a2, a3);   return }
    if (path == "app.all")    { all(a1, a2);      return }
    if (path == "app.listen") { listen(a1);       return }
    print "hawk::dispatch: unknown path: " path > "/dev/stderr"
}

@namespace "awk"
