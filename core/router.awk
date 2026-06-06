# SPDX-License-Identifier: MIT
# core/router.awk -- ルート登録 + マッチング + ハンドラ呼出
#
# 戻り値:
#   1  -- マッチしてハンドラ実行済 (res 設定済)
#   0  -- マッチなし (呼出元が静的配信 → 404 を判断)
#   -1 -- メソッド違い (res に 405 設定済)

function GET(path, handler)    { _route_add("GET",    path, handler) }
function POST(path, handler)   { _route_add("POST",   path, handler) }
function PUT(path, handler)    { _route_add("PUT",    path, handler) }
function DELETE(path, handler) { _route_add("DELETE", path, handler) }
function PATCH(path, handler)  { _route_add("PATCH",  path, handler) }
function HEAD(path, handler)   { _route_add("HEAD",   path, handler) }

function _route_add(method, path, handler,    pattern, params, parts, n, i, seg) {
  # :name を ([^/]+) に変換し、params に名前を蓄積
  pattern = "^"
  params = ""
  n = split(path, parts, "/")
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "") {
      if (i > 1) pattern = pattern "/"
      continue
    }
    pattern = pattern "/"
    if (substr(seg, 1, 1) == ":") {
      pattern = pattern "([^/]+)"
      params = params (params == "" ? "" : ",") substr(seg, 2)
    } else {
      pattern = pattern _route_escape_re(seg)
    }
  }
  pattern = pattern "$"

  ROUTES[method, path, "handler"] = handler
  ROUTES[method, path, "pattern"] = pattern
  ROUTES[method, path, "params"]  = params
  ROUTES_ORDER[++ROUTES_COUNT] = method "\t" path
}

function _route_escape_re(s) {
  gsub(/[][().*+?^$|\\\/{}]/, "\\\\&", s)
  return s
}

function router_dispatch(req, res,    idx, key, k, pattern, arr, params, names, i, handler, allow_methods, allow_set, has_path) {
  has_path = 0
  allow_methods = ""

  for (idx = 1; idx <= ROUTES_COUNT; idx++) {
    key = ROUTES_ORDER[idx]
    split(key, k, "\t")
    pattern = ROUTES[k[1], k[2], "pattern"]
    if (match(req["path"], pattern, arr)) {
      if (k[1] == req["method"]) {
        params = ROUTES[k[1], k[2], "params"]
        if (params != "") {
          split(params, names, ",")
          for (i = 1; i in names; i++) req["params:" names[i]] = arr[i]
        }
        handler = ROUTES[k[1], k[2], "handler"]
        @handler(req, res)
        return 1
      } else {
        has_path = 1
        if (!(k[1] in allow_set)) {
          allow_set[k[1]] = 1
          allow_methods = allow_methods (allow_methods == "" ? "" : ", ") k[1]
        }
      }
    }
  }

  if (has_path) {
    status(res, 405)
    header(res, "Allow", allow_methods)
    text(res, "Method Not Allowed")
    return -1
  }
  return 0
}
