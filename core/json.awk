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

BEGIN {
  # ponytail: 32段ネストで打ち切り。要件が出たら設定化する。
  _JP_MAX_DEPTH = 32
  _json_init()
}

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
# json_decode(s, out, out_type) は JSON 文字列を フラットな連想配列に展開する。
# トップレベル object のみ許可（配列・スカラーは 0 を返す）。ネストした object / array は解析できる。
# 戻り値: 1=成功、0=失敗、-1=最大ネスト深度(_JP_MAX_DEPTH)超過。
# json_decode_value(s, out, out_type) は上記の制限を外し、トップレベルが配列・スカラーでも解析する。
# AWK フォールバック専用。戻り値: 1=成功、0=失敗、-1=最大ネスト深度(_JP_MAX_DEPTH)超過。

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
function _jp_parse_string(   buf, c, nx, hex) {
  _jp_i++
  buf = ""
  while (_jp_i <= _jp_n) {
    c = substr(_jp_s, _jp_i, 1)
    if (c == "\\") {
      nx = substr(_jp_s, _jp_i + 1, 1)
      if (nx !~ /^[\\\/"bfnrtu]$/) {
        _jp_parse_error = 1
        HAWK_JSON_ERROR = "invalid escape sequence"
        return ""
      }
      if (nx == "u") {
        hex = substr(_jp_s, _jp_i + 2, 4)
        if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
          _jp_parse_error = 1
          HAWK_JSON_ERROR = "invalid escape sequence"
          return ""
        }
      }
      buf = buf c nx
      _jp_i += 2
    } else if (c == "\"") {
      _jp_i++; return _json_unescape(buf)
    } else {
      buf = buf c; _jp_i++
    }
  }
  _jp_parse_error = 1
  HAWK_JSON_ERROR = "unterminated string"
  return ""
}
function _jp_parse_literal(out, path, out_type,   buf, c) {
  buf = ""
  while (_jp_i <= _jp_n) {
    c = substr(_jp_s, _jp_i, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
    buf = buf c; _jp_i++
  }
  out[path] = buf
  if (buf == "true" || buf == "false") out_type[path] = "bool"
  else if (buf == "null") out_type[path] = "null"
  else if (buf ~ /^-?(0|[1-9][0-9]*)$/) out_type[path] = "int"
  else if (buf ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?[eE][+-]?[0-9]+$/) out_type[path] = "float"
  else if (buf ~ /^-?(0|[1-9][0-9]*)\.[0-9]+$/) out_type[path] = "float"
}
function _jp_parse_object(out, path, out_type, depth,   c, key, subpath) {
  if (depth > _JP_MAX_DEPTH) { _jp_too_deep = 1; return }
  _jp_i++; _jp_skip()
  if (substr(_jp_s, _jp_i, 1) == "}") { _jp_i++; return }
  while (_jp_i <= _jp_n) {
    _jp_skip()
    if (substr(_jp_s, _jp_i, 1) != "\"") break
    key = _jp_parse_string(); _jp_skip()
    if (substr(_jp_s, _jp_i, 1) != ":") break
    _jp_i++; subpath = _jp_path(path, key)
    _jp_parse_value(out, subpath, out_type, depth + 1); _jp_skip()
    if (_jp_too_deep) return
    c = substr(_jp_s, _jp_i, 1)
    if (c == "}") { _jp_i++; return }
    if (c == ",") { _jp_i++; continue }
    break
  }
  if (_jp_i > _jp_n) {
    _jp_parse_error = 1
    HAWK_JSON_ERROR = "unexpected end of input"
  }
}
function _jp_parse_array(out, path, out_type, depth,   c, idx, subpath) {
  if (depth > _JP_MAX_DEPTH) { _jp_too_deep = 1; return }
  _jp_i++; idx = 0; _jp_skip()
  if (substr(_jp_s, _jp_i, 1) == "]") { _jp_i++; return }
  while (_jp_i <= _jp_n) {
    subpath = _jp_path(path, idx "")
    _jp_parse_value(out, subpath, out_type, depth + 1); _jp_skip()
    if (_jp_too_deep) return
    c = substr(_jp_s, _jp_i, 1)
    if (c == "]") { _jp_i++; return }
    if (c == ",") { _jp_i++; idx++; continue }
    break
  }
  if (_jp_i > _jp_n) {
    _jp_parse_error = 1
    HAWK_JSON_ERROR = "unexpected end of input"
  }
}
function _jp_parse_value(out, path, out_type, depth,   c) {
  if (depth > _JP_MAX_DEPTH) { _jp_too_deep = 1; return }
  _jp_skip(); c = substr(_jp_s, _jp_i, 1)
  if      (c == "{")  _jp_parse_object(out, path, out_type, depth)
  else if (c == "[")  _jp_parse_array(out, path, out_type, depth)
  else if (c == "\"") { out[path] = _jp_parse_string(); out_type[path] = "string" }
  else                _jp_parse_literal(out, path, out_type)
}
function json_decode(s, out, out_type,   raw, n, i, recs, rest, sep1, sep2, k, v, t, first) {
  delete out
  delete out_type
  HAWK_JSON_ERROR = ""
  # Zig/AWK 両方で最初に object 判定してトップレベル非 object を確実に弾く
  _jp_s = s; _jp_n = length(s); _jp_i = 1
  _jp_skip()
  if (_jp_i > _jp_n) return 0
  first = substr(_jp_s, _jp_i, 1)
  if (first != "{") return 0
  _jp_too_deep = 0
  _jp_parse_error = 0
  _jp_parse_object(out, "", out_type, 1)
  if (_jp_too_deep) return -1
  if (_jp_parse_error) return 0
  _jp_skip()
  if (_jp_i <= _jp_n) {
    HAWK_JSON_ERROR = "invalid JSON"
    return 0
  }
  for (k in out) {
    if (!(k in out_type)) return 0
  }
  if (LIBS_LOADED["json"]) {
    delete out
    delete out_type
    raw = hawk_json_decode(s)
    if (raw == "" && hawk_json_error() != "") {
      HAWK_JSON_ERROR = hawk_json_error()
      return 0
    }
    HAWK_JSON_ERROR = ""
    n = split(raw, recs, "\x1e")
    for (i = 1; i <= n; i++) {
      if (recs[i] == "") continue
      sep1 = index(recs[i], "\x1f")
      if (sep1 == 0) continue
      k = awk::_adt_b64_decode(substr(recs[i], 1, sep1 - 1))
      rest = substr(recs[i], sep1 + 1)
      sep2 = index(rest, "\x1f")
      if (sep2 == 0) continue
      v = awk::_adt_b64_decode(substr(rest, 1, sep2 - 1))
      t = substr(rest, sep2 + 1)
      out[k] = v
      out_type[k] = t
    }
    return 1
  }
  return 1
}

function json_decode_value(s, out, out_type,   k, first) {
  delete out
  delete out_type
  HAWK_JSON_ERROR = ""
  _jp_s = s; _jp_n = length(s); _jp_i = 1; _jp_too_deep = 0; _jp_parse_error = 0
  _jp_skip()
  if (_jp_i > _jp_n) return 0
  first = substr(_jp_s, _jp_i, 1)
  _jp_root_kind = (first == "{") ? "object" : ((first == "[") ? "array" : "scalar")
  _jp_parse_value(out, "", out_type, 1)
  if (_jp_too_deep) return -1
  if (_jp_parse_error) return 0
  _jp_skip()
  if (_jp_i <= _jp_n) return 0
  for (k in out) {
    if (!(k in out_type)) return 0
  }
  return 1
}

@namespace "json"

function encode(data) {
  return awk::json_encode(data)
}

function decode(s,    ok, out, out_type, msg) {
  ok = awk::json_decode_value(s, out, out_type)
  if (ok == -1) return awk::result_ng("JsonTooDeepError", "max nesting depth exceeded")
  if (ok == 0) {
    msg = (awk::HAWK_JSON_ERROR != "") ? awk::HAWK_JSON_ERROR : "invalid JSON"
    return awk::result_ng("JsonParseError", msg)
  }
  return awk::result_ok_from_map(out, out_type)
}

function decode_object(s,    ok, out, out_type, msg) {
  ok = awk::json_decode(s, out, out_type)
  if (ok == -1) return awk::result_ng("JsonTooDeepError", "max nesting depth exceeded")
  if (!ok) {
    msg = (awk::HAWK_JSON_ERROR != "") ? awk::HAWK_JSON_ERROR : "invalid JSON"
    return awk::result_ng("JsonParseError", msg)
  }
  return awk::result_ok_from_map(out, out_type)
}

function decode_t(type, s,    ok, out, out_type, msg, k, has_leaf) {
  ok = awk::json_decode_value(s, out, out_type)
  if (ok == -1) return awk::result_ng("JsonTooDeepError", "max nesting depth exceeded")
  if (ok == 0) {
    msg = (awk::HAWK_JSON_ERROR != "") ? awk::HAWK_JSON_ERROR : "invalid JSON"
    return awk::result_ng("JsonParseError", msg)
  }
  if (_is_container_type(type)) {
    if (type == "Array" && awk::_jp_root_kind != "array")
      return awk::result_ng("JsonTypeError", "type mismatch: expected Array but got non-array root")
    if ((type == "JsonObject" || type == "Map") && awk::_jp_root_kind != "object")
      return awk::result_ng("JsonTypeError", "type mismatch: expected " type " but got non-object root")
    if (type == "JsonScalar" && awk::_jp_root_kind != "scalar")
      return awk::result_ng("JsonTypeError", "type mismatch: expected JsonScalar but got non-scalar root")
    return awk::result_ok_from_map(out, out_type)
  }
  has_leaf = 0
  for (k in out) {
    has_leaf = 1
    if (!_validate_leaf(type, out[k], out_type[k]))
      return awk::result_ng("JsonTypeError", "type mismatch: expected " type " at " k)
  }
  if (!has_leaf && type != "Any")
    return awk::result_ng("JsonTypeError", "type mismatch: expected " type " but got empty container")
  return awk::result_ok_from_map(out, out_type)
}

function _validate_leaf(t, v, vtype) {
  if (t == "Int")   return vtype == "int"
  if (t == "Float") return vtype == "float" || vtype == "int"
  if (t == "Bool")  return vtype == "bool"
  if (t == "Str")   return vtype == "string"
  if (t == "Null")  return vtype == "null"
  if (t == "Any")   return 1
  return 0
}

function _is_container_type(t) {
  return t == "JsonValue" || t == "JsonObject" || t == "Array" || t == "Map" || t == "JsonScalar"
}

function dispatch(path, a1, a2, a3) {
  return hawk_dispatch::call("json", _JSON_ROUTES, _JSON_ARITY, path, a1, a2, a3)
}

BEGIN {
  _JSON_ROUTES["encode"]        = "json::encode";        _JSON_ARITY["encode"]        = 1
  _JSON_ROUTES["decode"]        = "json::decode";        _JSON_ARITY["decode"]        = 1
  _JSON_ROUTES["decode_object"] = "json::decode_object"; _JSON_ARITY["decode_object"] = 1
  _JSON_ROUTES["decode_t"]      = "json::decode_t";      _JSON_ARITY["decode_t"]      = 2
}
