# SPDX-License-Identifier: MIT
# core/response.awk -- res[] 操作 API + HTTP wire format
#
# API:
#   status(res, code)
#   header(res, name, value)             -- 上書き
#   header_append(res, name, value)      -- 既存に追加 (LF区切り内部表現)
#   redirect(res, location [, code])
#   json(res, data [, code])
#   text(res, body [, code])
#   html(res, body [, code])
#   render(res, path [, code])           -- views/ から HTML をそのまま読込
#   response_wire(res) → 文字列 (HTTP/1.1 整形済)

function status(res, code) {
  res["status"] = code
}

function header(res, name, value) {
  gsub(/[\r\n]/, "", value)
  res["header:" to_lower(name)] = value
}

function header_append(res, name, value,    key) {
  gsub(/[\r\n]/, "", value)
  key = "header:" to_lower(name)
  if (key in res && res[key] != "") {
    res[key] = res[key] "\n" value
  } else {
    res[key] = value
  }
}

function redirect(res, location, code) {
  gsub(/[\r\n]/, "", location)
  res["status"] = (code != "" && code != 0) ? code : 302
  res["header:location"] = location
  res["body"] = ""
}

function json(res, data, code,    body) {
  body = json_encode(data)
  if (code != "" && code != 0) res["status"] = code
  else if (!("status" in res)) res["status"] = 200
  res["header:content-type"] = "application/json; charset=utf-8"
  res["body"] = body
}

function text(res, body, code) {
  if (code != "" && code != 0) res["status"] = code
  else if (!("status" in res)) res["status"] = 200
  res["header:content-type"] = "text/plain; charset=utf-8"
  res["body"] = body
}

function html(res, body, code) {
  if (code != "" && code != 0) res["status"] = code
  else if (!("status" in res)) res["status"] = 200
  res["header:content-type"] = "text/html; charset=utf-8"
  res["body"] = body
}

function render(res, path, code,    body) {
  body = template_read(path)
  if (body == "") {
    res["status"] = 500
    res["header:content-type"] = "text/plain; charset=utf-8"
    res["body"] = "Template not found: " path
    return
  }
  html(res, body, code)
}

function response_wire(res,    out, k, name, code_text, np, i, lines) {
  if (!("status" in res)) res["status"] = 200
  code_text = response_status_text(res["status"])
  out = sprintf("HTTP/1.1 %d %s\r\n", res["status"], code_text)

  # 必須ヘッダ
  if (!("header:content-length" in res)) {
    res["header:content-length"] = length(res["body"])
  }
  if (!("header:connection" in res)) {
    res["header:connection"] = "close"
  }

  for (k in res) {
    if (index(k, "header:") != 1) continue
    name = substr(k, 8)
    name = response_header_case(name)
    if (index(res[k], "\n") > 0) {
      np = split(res[k], lines, "\n")
      for (i = 1; i <= np; i++) {
        out = out sprintf("%s: %s\r\n", name, lines[i])
      }
    } else {
      out = out sprintf("%s: %s\r\n", name, res[k])
    }
  }
  out = out "\r\n" res["body"]
  return out
}

# send(res) -- 明示送信マーカー。実際の wire 送出は http.awk が行う。
# 二重送信防止用に res["sent"]=1 を立てる。ハンドラ内で `send(res); return`
# としても良いが、通常はハンドラ戻りで http.awk が自動送出する。
function send(res) {
  res["sent"] = 1
}

function response_header_case(name,    parts, n, i, out, c) {
  n = split(name, parts, "-")
  out = ""
  for (i = 1; i <= n; i++) {
    if (parts[i] == "") continue
    c = substr(parts[i], 1, 1)
    if (c in UTIL_UPPER) c = UTIL_UPPER[c]
    out = out (i > 1 ? "-" : "") c substr(parts[i], 2)
  }
  return out
}

function response_status_text(code) {
  if (code == 200) return "OK"
  if (code == 201) return "Created"
  if (code == 204) return "No Content"
  if (code == 301) return "Moved Permanently"
  if (code == 302) return "Found"
  if (code == 303) return "See Other"
  if (code == 304) return "Not Modified"
  if (code == 400) return "Bad Request"
  if (code == 401) return "Unauthorized"
  if (code == 403) return "Forbidden"
  if (code == 404) return "Not Found"
  if (code == 405) return "Method Not Allowed"
  if (code == 413) return "Payload Too Large"
  if (code == 431) return "Request Header Fields Too Large"
  if (code == 500) return "Internal Server Error"
  if (code == 503) return "Service Unavailable"
  return "Unknown"
}
