# SPDX-License-Identifier: MIT
# core/url.awk -- URL encode/decode (AWK fallback)

function url_encode(s,    out, i, c, n) {
  if (LIBS_LOADED["url"]) return hawk_url_encode(s)
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c ~ /[A-Za-z0-9\-_.~]/) { out = out c }
    else { out = out sprintf("%%%02X", _URL_ORD[c]) }
  }
  return out
}

function url_decode_form(s,    out, i, c, hex, n) {
  if (LIBS_LOADED["url"]) {
    out = hawk_url_decode_form(s)
    HAWK_URL_ERROR = hawk_url_error()
    return out
  }
  HAWK_URL_ERROR = ""
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "+") { out = out " "; i++; continue }
    if (c == "%") {
      if (i + 2 > n) { HAWK_URL_ERROR = "InvalidPercentEncoding"; return "" }
      hex = substr(s, i + 1, 2)
      if (hex !~ /^[0-9A-Fa-f]{2}$/) { HAWK_URL_ERROR = "InvalidPercentEncoding"; return "" }
      out = out _url_hex2byte(hex); i += 3; continue
    }
    out = out c; i++
  }
  return out
}

function url_query_parse(s, out,    pairs, n, i, kv) {
  delete out; n = split(s, pairs, "&")
  for (i = 1; i <= n; i++) {
    if (split(pairs[i], kv, "=") >= 1) {
      out[url_decode_form(kv[1])] = (length(kv) >= 2) ? url_decode_form(kv[2]) : ""
    }
  }
  return n
}

function url_query_string(arr,    k, out, sep) {
  out = ""; sep = ""
  for (k in arr) {
    out = out sep url_encode(k) "=" url_encode(arr[k])
    sep = "&"
  }
  return out
}

function _url_hex2byte(hex,    hi, lo) {
  hi = index("0123456789ABCDEF", toupper(substr(hex, 1, 1))) - 1
  lo = index("0123456789ABCDEF", toupper(substr(hex, 2, 1))) - 1
  return sprintf("%c", hi * 16 + lo)
}

BEGIN {
  for (_url_i = 0; _url_i < 256; _url_i++) {
    _URL_ORD[sprintf("%c", _url_i)] = _url_i
  }
}
