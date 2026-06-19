# SPDX-License-Identifier: MIT
# core/json.awk -- 最小 JSON encode / decode
#
# json_encode(data) は data[] 連想配列を JSON 文字列に変換する。
# キーに :int / :bool / :null サフィックスがあれば型ヒントとして扱う。
#
# json_decode(s, out) は JSON 文字列を フラットな連想配列に展開する。
# トップレベル object のみ。ネスト object / array は v0.1 では未サポート。
# 戻り値: 1=成功、0=失敗。

function json_encode(data,    keys, n, i, out, pieces, type_pos, key, name, type, val) {
  out = "{"
  n = 0
  for (key in data) {
    keys[++n] = key
  }
  for (i = 1; i <= n; i++) {
    key = keys[i]
    val = data[key]
    type_pos = index(key, ":")
    if (type_pos > 0) {
      name = substr(key, 1, type_pos - 1)
      type = substr(key, type_pos + 1)
    } else {
      name = key
      type = "string"
    }
    pieces[i] = "\"" _json_escape(name) "\":" _json_value(val, type)
  }
  for (i = 1; i <= n; i++) {
    out = out pieces[i] (i < n ? "," : "")
  }
  return out "}"
}

function _json_value(val, type) {
  if (type == "int" || type == "number") return val + 0
  if (type == "bool")                    return (val + 0 != 0 || val == "true") ? "true" : "false"
  if (type == "null")                    return "null"
  if (type == "raw")                     return val
  return "\"" _json_escape(val) "\""
}

function _json_escape(s,    out) {
  out = s
  gsub(/\\/, "\\\\", out)
  gsub(/"/,  "\\\"", out)
  gsub(/\n/, "\\n",  out)
  gsub(/\r/, "\\r",  out)
  gsub(/\t/, "\\t",  out)
  return out
}

function _json_escape_str(s) {
  return _json_escape(s)
}

function _json_encode_array(arr,    i, n, out, sep) {
  n = 0; for (i in arr) { if (i+0 > n && i == i+0) n = i+0 }
  out = "["; sep = ""
  for (i = 1; i <= n; i++) {
    out = out sep json_encode_any(arr[i])
    sep = ","
  }
  return out "]"
}

function _json_encode_object(obj,    k, out, sep) {
  out = "{"; sep = ""
  for (k in obj) {
    if (k == "__json_type") continue
    out = out sep "\"" _json_escape_str(k) "\":" json_encode_any(obj[k])
    sep = ","
  }
  return out "}"
}

function json_encode_any(val,    t) {
  t = typeof(val)
  if (t == "array") {
    if (val["__json_type"] == "array") return _json_encode_array(val)
    return _json_encode_object(val)
  }
  if (t == "number") return val + 0
  return "\"" _json_escape_str(val) "\""
}

# 簡易 JSON decoder: トップレベル object のみ。値は string / number / true / false / null
# にフラットに対応する。ネスト object / array は MVP では未サポート。
function json_decode(s, out,    i, n, c, key, val, buf) {
  delete out
  s = trim(s)
  if (substr(s, 1, 1) != "{" || substr(s, length(s), 1) != "}") return 0
  s = substr(s, 2, length(s) - 2)

  i = 1; n = length(s)
  while (i <= n) {
    while (i <= n && (c = substr(s, i, 1)) ~ /[ \t\n\r]/) i++
    if (i > n) break
    if (substr(s, i, 1) != "\"") return 0
    i++
    buf = ""
    while (i <= n && (c = substr(s, i, 1)) != "\"") {
      if (c == "\\" && i < n) {
        buf = buf _json_unescape(substr(s, i + 1, 1))
        i += 2
      } else {
        buf = buf c
        i++
      }
    }
    if (i > n) return 0
    key = buf
    i++

    while (i <= n && (c = substr(s, i, 1)) ~ /[ \t\n\r]/) i++
    if (substr(s, i, 1) != ":") return 0
    i++
    while (i <= n && (c = substr(s, i, 1)) ~ /[ \t\n\r]/) i++

    c = substr(s, i, 1)
    if (c == "\"") {
      i++
      buf = ""
      while (i <= n && (c = substr(s, i, 1)) != "\"") {
        if (c == "\\" && i < n) {
          buf = buf _json_unescape(substr(s, i + 1, 1))
          i += 2
        } else {
          buf = buf c
          i++
        }
      }
      if (i > n) return 0
      out[key] = buf
      i++
    } else if (c ~ /[-0-9]/) {
      buf = ""
      while (i <= n && substr(s, i, 1) ~ /[-0-9.eE+]/) {
        buf = buf substr(s, i, 1)
        i++
      }
      out[key] = buf
    } else if (substr(s, i, 4) == "true") {
      out[key] = "true"; i += 4
    } else if (substr(s, i, 5) == "false") {
      out[key] = "false"; i += 5
    } else if (substr(s, i, 4) == "null") {
      out[key] = "null"; i += 4
    } else {
      return 0
    }

    while (i <= n && (c = substr(s, i, 1)) ~ /[ \t\n\r]/) i++
    if (i > n) break
    if (substr(s, i, 1) != ",") return 0
    i++
  }
  return 1
}

function _json_unescape(c) {
  if (c == "n") return "\n"
  if (c == "r") return "\r"
  if (c == "t") return "\t"
  if (c == "\"") return "\""
  if (c == "\\") return "\\"
  if (c == "/") return "/"
  return c
}
