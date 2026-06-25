# SPDX-License-Identifier: MIT
# core/router.awk -- ルート登録 + マッチング + ハンドラ呼出
#
# 戻り値:
#   1  -- マッチしてハンドラ実行済 (res 設定済)
#   0  -- マッチなし (呼出元が静的配信 → 404 を判断)
#   -1 -- メソッド違い (res に 405 設定済)

function GET(p, h)    { hawk::get(p, h) }
function POST(p, h)   { hawk::post(p, h) }
function PUT(p, h)    { hawk::put(p, h) }
function DELETE(p, h) { hawk::del(p, h) }
function PATCH(p, h)  { hawk::patch(p, h) }
function HEAD(p, h)   { hawk::head(p, h) }
function QUERY(p, h, types) { hawk::query(p, h, types) }

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
  return pattern
}

function _route_escape_re(s) {
  gsub(/[][().*+?^$|\\\/{}]/, "\\\\&", s)
  return s
}

function _route_add_query(path, handler, types,    pattern, i, s) {
  pattern = _route_add("QUERY", path, handler)
  if (pattern == "") return
  s = ""
  if (isarray(types)) {
    for (i in types) {
      s = s (s == "" ? "" : ",") types[i]
    }
  }
  ROUTES_QUERY_TYPES[pattern] = s
}

function _query_inject_accept_header(res, pattern,    v) {
  v = ROUTES_QUERY_TYPES[pattern]
  res["header:accept-query"] = (v == "" ? "*/*" : v)
}

function _route_split_types(s, arr,    n) {
  delete arr
  if (s == "") return
  n = split(s, arr, ",")
}

function router_dispatch(req, res,    idx, key, k, pattern, arr, params, names, i, handler, allow_methods, allow_set, has_path, _qt, vret, _opt_k, _opt_parts, _opt_allow_set, _opt_allow_methods, _opt_pattern, _opt_has_query, _opt_has_explicit_options, matched_query_pattern) {
  has_path = 0
  allow_methods = ""

  if (req["method"] == "OPTIONS") {
    _opt_has_explicit_options = 0
    for (_opt_k in ROUTES) {
      split(_opt_k, _opt_parts, SUBSEP)
      if (_opt_parts[3] != "pattern") continue
      if (req["path"] !~ ROUTES[_opt_k]) continue
      if (_opt_parts[1] == "OPTIONS") { _opt_has_explicit_options = 1; break }
    }
    if (!_opt_has_explicit_options) {
      delete _opt_allow_set
      _opt_allow_methods = ""
      _opt_pattern = ""
      _opt_has_query = 0
      for (_opt_k in ROUTES) {
        split(_opt_k, _opt_parts, SUBSEP)
        if (_opt_parts[3] != "pattern") continue
        if (req["path"] !~ ROUTES[_opt_k]) continue
        if (!(_opt_parts[1] in _opt_allow_set)) {
          _opt_allow_set[_opt_parts[1]] = 1
          _opt_allow_methods = _opt_allow_methods (_opt_allow_methods == "" ? "" : ", ") _opt_parts[1]
        }
        if (_opt_parts[1] == "QUERY") {
          _opt_has_query = 1
          _opt_pattern = ROUTES[_opt_k]
        }
      }
      if (_opt_allow_methods != "") {
        _opt_allow_methods = _opt_allow_methods ", OPTIONS"
        status(res, 204)
        header(res, "Allow", _opt_allow_methods)
        if (_opt_has_query) _query_inject_accept_header(res, _opt_pattern)
        return 1
      }
      return 0
    }
  }

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
        if (k[1] == "QUERY") {
          _route_split_types(ROUTES_QUERY_TYPES[pattern], _qt)
          vret = request_validate_content_type(req, _qt, res)
          delete _qt
          if (vret == 0) return -1
          if (vret == -1) {
            _query_inject_accept_header(res, pattern)
            return -1
          }
        }
        _ctx_load(req, res)
        @handler()
        _ctx_save(res)
        if (k[1] == "QUERY") _query_inject_accept_header(res, pattern)
        return 1
      } else {
        has_path = 1
        if (!(k[1] in allow_set)) {
          allow_set[k[1]] = 1
          allow_methods = allow_methods (allow_methods == "" ? "" : ", ") k[1]
        }
        if (k[1] == "QUERY") matched_query_pattern = pattern
      }
    }
  }

  if (has_path) {
    status(res, 405)
    header(res, "Allow", allow_methods)
    if ("QUERY" in allow_set) {
      _query_inject_accept_header(res, matched_query_pattern)
    }
    text(res, "Method Not Allowed")
    return -1
  }
  return 0
}
