# SPDX-License-Identifier: MIT
# core/hawk.awk -- hawk:: App API (Hono-style)
#
# hawk:: は H-awk の一次ルーティング API。
# GET/POST/... は後方互換エイリアスとして core/router.awk で定義する。

@namespace "hawk"

BEGIN {
    _HAWK_ROUTES["app.get"]    = "hawk::get";    _HAWK_ARITY["app.get"]    = 2
    _HAWK_ROUTES["app.post"]   = "hawk::post";   _HAWK_ARITY["app.post"]   = 2
    _HAWK_ROUTES["app.put"]    = "hawk::put";    _HAWK_ARITY["app.put"]    = 2
    _HAWK_ROUTES["app.del"]    = "hawk::del";    _HAWK_ARITY["app.del"]    = 2
    _HAWK_ROUTES["app.patch"]  = "hawk::patch";  _HAWK_ARITY["app.patch"]  = 2
    _HAWK_ROUTES["app.head"]   = "hawk::head";   _HAWK_ARITY["app.head"]   = 2
    _HAWK_ROUTES["app.on"]     = "hawk::on";     _HAWK_ARITY["app.on"]     = 3
    _HAWK_ROUTES["app.all"]    = "hawk::all";    _HAWK_ARITY["app.all"]    = 2
    _HAWK_ROUTES["app.listen"] = "hawk::listen"; _HAWK_ARITY["app.listen"] = 1
}

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
    if (port !~ /^[0-9]+$/ || port + 0 == 0 || port + 0 > 65535) {
        print "hawk::listen: invalid port: \"" port "\"" > "/dev/stderr"
        exit 1
    }
    awk::listen(port + 0)
}

# dispatch: DSL desugar target — hawk.app.get(...) → hawk::dispatch("app.get", ...)
function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("hawk", _HAWK_ROUTES, _HAWK_ARITY, path, a1, a2, a3)
}

@namespace "awk"
