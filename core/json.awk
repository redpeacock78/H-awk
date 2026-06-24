# SPDX-License-Identifier: MIT
# --- Unicode unescape 用ルックアップテーブル（ko1nksm CC0 ベース）--------------

# BEGIN から呼ぶ。ルックアップテーブルを初期化する。
function _json_init(   i) {
  for (i = 0; i <= 127; i++)
    _jhex2chr[sprintf("%02x", i)] = sprintf("%c", i)
  _jesc2chr["b"]  = _jhex2chr["08"]
  _jesc2chr["t"]  = _jhex2chr["09"]
  _jesc2chr["n"]  = _jhex2chr["0a"]
  _jesc2chr["f"]  = _jhex2chr["0c"]
  _jesc2chr["r"]  = _jhex2chr["0d"]
  _jesc2chr["\""] = _jhex2chr["22"]
  _jesc2chr["/"]  = _jhex2chr["2f"]
  _jesc2chr["\\"] = "\\"
  for (i = 0; i <= 255; i++)
    _jhex2dec[sprintf("%02x", i)] = i
}

BEGIN { _json_init() }

END {
  delete _jhex2chr
  delete _jesc2chr
  delete _jhex2dec
}

# 4桁16進文字列 hex を整数に変換する。
function _j_hex2dec(hex,   h) {
  h = tolower(hex)
  return _jhex2dec[substr(h, 1, 2)] * 256 + _jhex2dec[substr(h, 3, 2)]
}

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

function _json_unescape(s,   ret, arr, n, i, part, cp, c1, c2, c3, c4) {
  n = split(s, arr, "\\")
  ret = arr[1]
  for (i = 2; i <= n; i++) {
    part = arr[i]
    if (part == "") {
      ret = ret "\\" arr[++i]
    } else if (match(part, /^[btnfr"\/\\]/)) {
      ret = ret _jesc2chr[substr(part, 1, 1)] substr(part, 2)
    } else if (match(part, /^u[Dd][89AaBb][0-9A-Fa-f][0-9A-Fa-f]/)) {
      cp = (_j_hex2dec(substr(part, 2, 4)) - 55296) * 1024
      i++; part = arr[i]
      if (part == "") { part = arr[++i] }
      if (match(part, /^u[Dd][CcDdEeFf][0-9A-Fa-f][0-9A-Fa-f]/)) {
        cp += _j_hex2dec(substr(part, 2, 4)) - 56320 + 65536
        c1 = 240 + int(cp / 262144); c2 = 128 + int(cp / 4096) % 64
        c3 = 128 + int(cp / 64) % 64; c4 = 128 + cp % 64
        ret = ret sprintf("%c%c%c%c", c1, c2, c3, c4) substr(part, 6)
      } else {
        ret = ret "\\u" substr(arr[i-1], 2, 4) "\\" part
      }
    } else if (match(part, /^u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
      cp = _j_hex2dec(substr(part, 2, 4))
      if (cp <= 127) {
        ret = ret _jhex2chr[tolower(substr(part, 4, 2))] substr(part, 6)
      } else if (cp <= 2047) {
        c1 = 192 + int(cp / 64); c2 = 128 + cp % 64
        ret = ret sprintf("%c%c", c1, c2) substr(part, 6)
      } else {
        c1 = 224 + int(cp / 4096); c2 = 128 + int(cp / 64) % 64; c3 = 128 + cp % 64
        ret = ret sprintf("%c%c%c", c1, c2, c3) substr(part, 6)
      }
    } else {
      ret = ret "\\" part
    }
  }
  return ret
}

function _jp_skip(   c) {
  while (_jp_i <= _jp_n) {
    c = substr(_jp_s, _jp_i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") _jp_i++
    else break
  }
}
function _jp_path(parent, child) {
  return (parent == "") ? child : parent "." child
}
function _jp_parse_string(   buf, c, nx) {
  _jp_i++
  buf = ""
  while (_jp_i <= _jp_n) {
    c = substr(_jp_s, _jp_i, 1)
    if (c == "\\") {
      nx = substr(_jp_s, _jp_i + 1, 1)
      buf = buf c nx
      _jp_i += 2
    } else if (c == "\"") {
      _jp_i++; return _json_unescape(buf)
    } else {
      buf = buf c; _jp_i++
    }
  }
  return _json_unescape(buf)
}
function _jp_parse_literal(out, path,   buf, c) {
  buf = ""
  while (_jp_i <= _jp_n) {
    c = substr(_jp_s, _jp_i, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
    buf = buf c; _jp_i++
  }
  out[path] = buf
}
function _jp_parse_object(out, path,   c, key, subpath) {
  _jp_i++; _jp_skip()
  if (substr(_jp_s, _jp_i, 1) == "}") { _jp_i++; return }
  while (_jp_i <= _jp_n) {
    _jp_skip()
    if (substr(_jp_s, _jp_i, 1) != "\"") break
    key = _jp_parse_string(); _jp_skip()
    if (substr(_jp_s, _jp_i, 1) != ":") break
    _jp_i++; subpath = _jp_path(path, key)
    _jp_parse_value(out, subpath); _jp_skip()
    c = substr(_jp_s, _jp_i, 1)
    if (c == "}") { _jp_i++; return }
    if (c == ",") { _jp_i++; continue }
    break
  }
}
function _jp_parse_array(out, path,   c, idx, subpath) {
  _jp_i++; idx = 0; _jp_skip()
  if (substr(_jp_s, _jp_i, 1) == "]") { _jp_i++; return }
  while (_jp_i <= _jp_n) {
    subpath = _jp_path(path, idx "")
    _jp_parse_value(out, subpath); _jp_skip()
    c = substr(_jp_s, _jp_i, 1)
    if (c == "]") { _jp_i++; return }
    if (c == ",") { _jp_i++; idx++; continue }
    break
  }
}
function _jp_parse_value(out, path,   c) {
  _jp_skip(); c = substr(_jp_s, _jp_i, 1)
  if      (c == "{")  _jp_parse_object(out, path)
  else if (c == "[")  _jp_parse_array(out, path)
  else if (c == "\"") out[path] = _jp_parse_string()
  else                _jp_parse_literal(out, path)
}
function json_decode(s, out,   first) {
  delete out
  if (LIBS_LOADED["json"] && hawk_json_valid(s) + 0 == 0) {
    HAWK_JSON_ERROR = hawk_json_error()
    return 0
  }
  HAWK_JSON_ERROR = ""
  _jp_s = s; _jp_n = length(s); _jp_i = 1
  _jp_skip()
  if (_jp_i > _jp_n) return 0
  first = substr(_jp_s, _jp_i, 1)
  if (first != "{") return 0
  _jp_parse_value(out, "")
  return 1
}
