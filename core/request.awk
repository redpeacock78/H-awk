# core/request.awk -- raw HTTP 文字列 → req[] 連想配列
#
# 入力: raw 文字列 (CRLF 区切り、Content-Length 分の body を含む完全なリクエスト)
# 出力: req[] 連想配列 (詳細は spec section 5.1)
# 戻り値: 1=パース成功, 0=不正リクエスト
#
# 注: 実際の socket 読込は http.awk が担当する。この関数は完全に組み立てた raw に対し
# 純関数として動く (テスト容易性のため)。
#
# 注意: _ARR_COUNT[] はグローバル配列。サーバーループ (Task 11, http.awk) では
# 各リクエスト処理前に `delete _ARR_COUNT` が必要。さもなければ foo[]= のカウントが
# リクエストをまたいで増え続ける。

function request_parse(raw, req,    parts, headers_raw, body, lines, n, i, line, k, v, q, m, j) {
  delete req
  req["raw"] = raw

  # head と body を \r\n\r\n で分割
  m = index(raw, "\r\n\r\n")
  if (m == 0) return 0
  headers_raw = substr(raw, 1, m - 1)
  body        = substr(raw, m + 4)

  n = split(headers_raw, lines, "\r\n")
  if (n < 1) return 0

  # request-line
  if (split(lines[1], parts, " ") != 3) return 0
  req["method"]       = parts[1]
  req["full_path"]    = parts[2]
  req["http_version"] = parts[3]

  if (req["method"] !~ /^[A-Z]+$/) return 0
  if (req["http_version"] !~ /^HTTP\/[0-9]\.[0-9]$/) return 0

  # path / query 分離
  q = index(req["full_path"], "?")
  if (q > 0) {
    req["path"]         = substr(req["full_path"], 1, q - 1)
    req["query_string"] = substr(req["full_path"], q + 1)
  } else {
    req["path"]         = req["full_path"]
    req["query_string"] = ""
  }

  # headers
  for (i = 2; i <= n; i++) {
    line = lines[i]
    if (line == "") continue
    j = index(line, ":")
    if (j == 0) continue
    k = to_lower(trim(substr(line, 1, j - 1)))
    v = trim(substr(line, j + 1))
    req["header:" k] = v
  }

  # query parse
  if (req["query_string"] != "") {
    _request_parse_kv(req["query_string"], req, "query:")
  }

  # body
  req["body"] = body
  if (length(body) > 0) {
    if (index(req["header:content-type"], "application/x-www-form-urlencoded") == 1) {
      _request_parse_kv(body, req, "form:")
    } else if (index(req["header:content-type"], "application/json") == 1) {
      _request_parse_json_body(body, req)
    }
  }

  return 1
}

function _request_parse_kv(s, req, prefix,    pairs, np, i, eq, k, v) {
  np = split(s, pairs, "&")
  for (i = 1; i <= np; i++) {
    if (pairs[i] == "") continue
    eq = index(pairs[i], "=")
    if (eq > 0) {
      k = url_decode(substr(pairs[i], 1, eq - 1))
      v = url_decode(substr(pairs[i], eq + 1))
    } else {
      k = url_decode(pairs[i])
      v = ""
    }
    # 配列構文 foo[]=a&foo[]=b → req[prefix "foo[]", 1] = "a" ...
    if (k ~ /\[\]$/) {
      _ARR_COUNT[prefix k]++
      req[prefix k, _ARR_COUNT[prefix k]] = v
    } else {
      req[prefix k] = v
    }
  }
}

function _request_parse_json_body(body, req,    flat, key) {
  delete flat
  if (json_decode(body, flat)) {
    for (key in flat) {
      req["json:" key] = flat[key]
    }
  }
}
