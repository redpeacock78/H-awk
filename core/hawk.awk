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

function on(methods, paths, handler,    ms, ps, i, j) {
  if (isarray(methods)) { for (i in methods) ms[i] = awk::to_upper(awk::trim(methods[i])) }
  else                  { ms[1] = awk::to_upper(awk::trim(methods)) }
  if (isarray(paths))   { for (i in paths)   ps[i] = awk::trim(paths[i]) }
  else                  { ps[1] = awk::trim(paths) }
  for (i in ms) for (j in ps) awk::_route_add(ms[i], ps[j], handler)
}

function all(paths, handler,    std_ms, ps, i, j) {
  split("GET POST PUT DELETE PATCH HEAD OPTIONS", std_ms, " ")
  if (isarray(paths)) { for (i in paths) ps[i] = awk::trim(paths[i]) }
  else                { ps[1] = awk::trim(paths) }
  for (i in std_ms) for (j in ps) awk::_route_add(std_ms[i], ps[j], handler)
}

function listen(port) { awk::listen(port) }

@namespace "awk"
