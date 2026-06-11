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

function listen(port) { awk::listen(port) }

@namespace "awk"
